using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using Windows.System;

namespace TablePro.App.Views;

// Settings apply as they change, as the Windows settings guidance has them; there is no Save.
public sealed partial class SettingsView : UserControl
{
    public static readonly Uri DocumentationUri = new("https://docs.tablepro.app");
    public static readonly Uri IssuesUri = new("https://github.com/TableProApp/TablePro/issues/new/choose");

    private readonly Workbench _workbench;
    private bool _loading;

    internal SettingsView(Workbench workbench)
    {
        _workbench = workbench;
        InitializeComponent();
        VersionText.Text = Strings.Format("VersionText", AppStorage.Version);
        DataFolderCard.Description = workbench.Folder;
        Load();
    }

    public void ShowAbout()
    {
        AboutExpander.IsExpanded = true;
        AboutExpander.StartBringIntoView();
    }

    private void Load()
    {
        _loading = true;
        var settings = _workbench.Settings;
        ThemeBox.SelectedIndex = settings.Theme switch
        {
            AppTheme.Light => 0,
            AppTheme.Dark => 1,
            _ => 2,
        };
        ReopenSwitch.IsOn = settings.ReopenSession;
        FontSizeBox.Value = settings.EditorFontSize;
        RowLimitBox.Value = settings.RowLimit;
        TimeoutBox.Value = settings.QueryTimeoutSeconds;
        // A size the file holds that the list does not offer is shown too, so the box never reads empty.
        PageSizeBox.Items.Clear();
        foreach (var size in AppSettings.PageSizeChoices.Append(settings.PageSize).Distinct().Order())
        {
            PageSizeBox.Items.Add(new ComboBoxItem { Content = Strings.Format("PageSizeOption", size), Tag = size });
        }

        PageSizeBox.SelectedItem = PageSizeBox.Items
            .OfType<ComboBoxItem>()
            .First(item => item.Tag is int size && size == settings.PageSize);
        _loading = false;
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ThemeBox.SelectedItem is not ComboBoxItem { Tag: string tag })
        {
            return;
        }

        var theme = Enum.Parse<AppTheme>(tag);
        _workbench.UpdateSettings(settings => settings with { Theme = theme });
    }

    private void OnReopenToggled(object sender, RoutedEventArgs e)
    {
        if (!_loading)
        {
            var reopen = ReopenSwitch.IsOn;
            _workbench.UpdateSettings(settings => settings with { ReopenSession = reopen });
        }
    }

    private void OnFontSizeChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { EditorFontSize = args.NewValue });
        }
    }

    private void OnRowLimitChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { RowLimit = (int)args.NewValue });
        }
    }

    private void OnPageSizeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && PageSizeBox.SelectedItem is ComboBoxItem { Tag: int size })
        {
            _workbench.UpdateSettings(settings => settings with { PageSize = size });
        }
    }

    private void OnTimeoutChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { QueryTimeoutSeconds = (int)args.NewValue });
        }
    }

    private async void OnDocumentation(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(DocumentationUri);

    private async void OnReportIssue(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(IssuesUri);

    // LaunchFolderPathAsync needs Windows 10 1903; this form runs on 1809.
    private async void OnOpenDataFolder(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchFolderAsync(await Windows.Storage.StorageFolder.GetFolderFromPathAsync(_workbench.Folder));
}
