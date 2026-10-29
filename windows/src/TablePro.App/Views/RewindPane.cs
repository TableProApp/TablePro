using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Licensing;
using TablePro.Storage.Rewind;
using ObjectName = TablePro.Core.Schema.ObjectName;

namespace TablePro.App.Views;

/// <summary>
/// The Data Rewind side pane: saves from the table grid, newest first, each with a Restore button that reviews the
/// statements putting its rows back. The list follows the journal, so a save made in any tab shows up as it commits.
/// Without a license covering Data Rewind the pane still opens and lists what was kept; Restore is where the license
/// is asked for, as on macOS.
/// </summary>
public sealed partial class RewindPane : UserControl
{
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
    private readonly DispatcherQueue _dispatcher;
    private readonly DialogService _dialogs;
    private readonly TextBlock _explanation = new()
    {
        TextWrapping = TextWrapping.Wrap,
        Opacity = 0.75,
        VerticalAlignment = VerticalAlignment.Center,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
    };

    private readonly HyperlinkButton _badge = ProFeatureGate.Badge(ProFeature.DataRewind);

    public RewindPane(RewindViewModel viewModel, DialogService dialogs)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ArgumentNullException.ThrowIfNull(dialogs);
        ViewModel = viewModel;
        _dialogs = dialogs;
        _dispatcher = DispatcherQueue.GetForCurrentThread();

        var tableOnly = new ToggleSwitch { Header = Strings.Get("Rewind/ThisTableOnly"), IsOn = viewModel.ThisTableOnly };
        tableOnly.Toggled += (_, _) => viewModel.ThisTableOnly = tableOnly.IsOn;

        var clear = new HyperlinkButton { Content = Strings.Get("Rewind/ClearSavedChanges"), HorizontalAlignment = HorizontalAlignment.Left };
        clear.Click += async (_, _) => await viewModel.ClearAsync();

        // A grid rather than a horizontal stack, so the sentence wraps beside the badge instead of running past the pane.
        var explanation = new Grid { ColumnSpacing = 6 };
        explanation.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        explanation.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        explanation.Children.Add(_explanation);
        Grid.SetColumn(_badge, 1);
        explanation.Children.Add(_badge);
        ShowLicense();

        var root = new Grid { Padding = new Thickness(12, 0, 12, 12), RowSpacing = 8 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(tableOnly);
        Grid.SetRow(_status, 1);
        root.Children.Add(_status);
        Grid.SetRow(_list, 2);
        root.Children.Add(_list);
        Grid.SetRow(explanation, 3);
        root.Children.Add(explanation);
        Grid.SetRow(clear, 4);
        root.Children.Add(clear);
        Content = root;

        viewModel.Entries.CollectionChanged += (_, _) => Rebuild();
        viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(RewindViewModel.StatusText) or nameof(RewindViewModel.IsBusy))
            {
                _status.Text = viewModel.StatusText ?? string.Empty;
                _list.IsEnabled = !viewModel.IsBusy;
            }
        };

        // The journal changes on a thread-pool thread when any tab saves; the list reloads on the UI thread.
        EventHandler onJournalChanged = (_, _) => _dispatcher.TryEnqueue(async () => await viewModel.RefreshAsync());
        // The kept saves stay listed without the license, as macOS keeps them in history; activating or removing one
        // with the pane open rewords it and its empty state at once.
        IDisposable? licenseWatch = null;
        Loaded += async (_, _) =>
        {
            RewindJournalService.Journal.Changed += onJournalChanged;
            licenseWatch = ProFeatureGate.Watch(ProFeature.DataRewind, _dispatcher, async () =>
            {
                ShowLicense();
                await viewModel.RefreshAsync();
            });
            ShowLicense();
            await viewModel.RefreshAsync();
        };
        Unloaded += (_, _) =>
        {
            RewindJournalService.Journal.Changed -= onJournalChanged;
            licenseWatch?.Dispose();
            licenseWatch = null;
        };
    }

    public RewindViewModel ViewModel { get; }

    /// <summary>The pane for a workspace, narrowed to the table of the selected tab when "This table only" is on.</summary>
    public static RewindPane Create(WorkspaceContext context, Func<ObjectName?> currentTable) =>
        new(new RewindViewModel(context, RewindJournalService.Journal, currentTable), context.Dialogs);

    private void ShowLicense()
    {
        var licensed = ProFeatureGate.IsAvailable(ProFeature.DataRewind);
        _explanation.Text = licensed ? Strings.Get("Rewind/Explanation") : Strings.Get("License/RewindNeedsLicense");
        _badge.Visibility = licensed ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Rebuild()
    {
        _list.Items.Clear();
        foreach (var entry in ViewModel.Entries)
        {
            _list.Items.Add(Row(entry));
        }
    }

    private Grid Row(RewindJournalEntry entry)
    {
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(new TextBlock { Text = entry.Table.Name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis });
        var detail = entry.Summary + " · " + entry.CapturedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
        if (entry.Restores is not null)
        {
            detail += " · " + Strings.Get("Rewind/IsRestore");
        }

        if (entry.RestoredAt is { } restored)
        {
            detail += " · " + Strings.Format("Rewind/RestoredAt", restored.ToLocalTime().ToString("t", CultureInfo.CurrentCulture));
        }

        text.Children.Add(new TextBlock { Text = detail, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
        if (entry.ReversibleCount < entry.OperationCount)
        {
            text.Children.Add(new TextBlock
            {
                Text = Strings.Plural("Rewind/RowsCannotBeRestored", entry.OperationCount - entry.ReversibleCount),
                Opacity = 0.7,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            });
        }

        var restore = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, IsEnabled = entry.ReversibleCount > 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(restore, Strings.Format("Rewind/RestoreButtonName", entry.Table.Name));
        ToolTipService.SetToolTip(restore, Strings.Get("Rewind/RestoreButtonTip"));
        restore.Click += async (_, _) =>
        {
            // Gated where it is used, as on macOS, so the button can explain what the license is for.
            if (await ProFeatureGate.EnsureAsync(ProFeature.DataRewind, _dialogs))
            {
                await ViewModel.RestoreAsync(entry);
            }
        };

        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 6, 0, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(text);
        Grid.SetColumn(restore, 1);
        row.Children.Add(restore);
        return row;
    }
}
