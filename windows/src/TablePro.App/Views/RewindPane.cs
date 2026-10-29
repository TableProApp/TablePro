using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Storage.Rewind;
using ObjectName = TablePro.Core.Schema.ObjectName;

namespace TablePro.App.Views;

/// <summary>
/// The Data Rewind side pane: saves from the table grid, newest first, each with a Restore button that reviews the
/// statements putting its rows back. The list follows the journal, so a save made in any tab shows up as it commits.
/// </summary>
public sealed partial class RewindPane : UserControl
{
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
    private readonly DispatcherQueue _dispatcher;

    public RewindPane(RewindViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ViewModel = viewModel;
        _dispatcher = DispatcherQueue.GetForCurrentThread();

        var tableOnly = new ToggleSwitch { Header = Strings.Get("Rewind/ThisTableOnly"), IsOn = viewModel.ThisTableOnly };
        tableOnly.Toggled += (_, _) => viewModel.ThisTableOnly = tableOnly.IsOn;

        var clear = new HyperlinkButton { Content = Strings.Get("Rewind/ClearSavedChanges"), HorizontalAlignment = HorizontalAlignment.Left };
        clear.Click += async (_, _) => await viewModel.ClearAsync();

        var explanation = new TextBlock
        {
            Text = Strings.Get("Rewind/Explanation"),
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.75,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        };

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
        Loaded += async (_, _) =>
        {
            RewindJournalService.Journal.Changed += onJournalChanged;
            await viewModel.RefreshAsync();
        };
        Unloaded += (_, _) => RewindJournalService.Journal.Changed -= onJournalChanged;
    }

    public RewindViewModel ViewModel { get; }

    /// <summary>The pane for a workspace, narrowed to the table of the selected tab when "This table only" is on.</summary>
    public static RewindPane Create(WorkspaceContext context, Func<ObjectName?> currentTable) =>
        new(new RewindViewModel(context, RewindJournalService.Journal, currentTable));

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
        restore.Click += async (_, _) => await ViewModel.RestoreAsync(entry);

        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 6, 0, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(text);
        Grid.SetColumn(restore, 1);
        row.Children.Add(restore);
        return row;
    }
}
