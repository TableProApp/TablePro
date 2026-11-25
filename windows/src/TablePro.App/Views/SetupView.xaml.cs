using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The setup guide, a page swapped into the window as Settings is (core 0049, windows/docs/decisions/0025).
public sealed partial class SetupView : UserControl, IDisposable
{
    private readonly Workbench _workbench;
    private readonly IShell _shell;
    private readonly IForeignImporter _importer;
    private readonly List<(string App, ForeignImportEnding Ending)> _endings = [];
    // The apps an import wrote from, by the name the core gives them, which is also their preset's name.
    private readonly List<string> _imported = [];
    private ImportFromAppPanel? _panel;
    private bool _loadingSources;
    private bool _sourcesShown;
    private bool _optionsShown;
    private bool _filling;
    private bool _ended;

    internal SetupView(Workbench workbench, IShell shell, IForeignImporter importer, SetupGuide guide)
    {
        _workbench = workbench;
        _shell = shell;
        _importer = importer;
        Guide = guide;
        InitializeComponent();
        AutomationProperties.SetName(this, Strings.Get("SetupViewName"));
        AutomationProperties.SetName(SourceList, Strings.Get("SetupSourcesName"));
        guide.Changed += (_, _) => Show();
        Show();
    }

    // Finish and Skip; leaving the page another way raises nothing.
    public event EventHandler<SetupEnding>? Ended;

    public event EventHandler? BackChanged;

    internal SetupGuide Guide { get; }

    // From a review back to the apps to tick; otherwise the guide's own step before.
    public bool CanGoBack => _panel is { } panel ? !panel.IsImporting : Guide.CanGoBack;

    public void Back()
    {
        if (_panel is { IsImporting: false })
        {
            DropPanel();
            Show();
            return;
        }

        Guide.Back();
    }

    // The window left the page: a read still running is let go, and nothing more ends the guide.
    public void Leave()
    {
        _ended = true;
        DropPanel();
    }

    public void Dispose() => DropPanel();

    private void Show()
    {
        var step = Guide.Step;
        OriginStep.Visibility = Shown(step == SetupStep.Origin);
        ImportStep.Visibility = Shown(step == SetupStep.Import);
        FirstConnectionStep.Visibility = Shown(step == SetupStep.FirstConnection);
        OptionsStep.Visibility = Shown(step == SetupStep.Options);
        StepTitle.Text = _panel is { } panel && step == SetupStep.Import
            ? panel.Title
            : Strings.Get("SetupTitle_" + step);
        StepDescription.Text = Strings.Get("SetupDescription_" + step);
        SkipButton.IsEnabled = _panel is not { IsImporting: true };
        switch (step)
        {
            case SetupStep.Origin:
                ShowPrimary(null, enabled: false);
                break;
            case SetupStep.Import:
                ShowImport();
                break;
            case SetupStep.FirstConnection:
                ShowChoice(NewConnectionChoice, Guide.Recorded == FirstConnectionChoice.NewConnection);
                ShowChoice(SampleChoice, Guide.Recorded == FirstConnectionChoice.Sample);
                ShowPrimary(Strings.Get("SetupContinue"), enabled: true);
                break;
            default:
                ShowOptions();
                ShowPrimary(Strings.Get("SetupFinish_" + Guide.End().GetType().Name), enabled: true);
                break;
        }

        BackChanged?.Invoke(this, EventArgs.Empty);
    }

    private static Visibility Shown(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    private void ShowPrimary(string? text, bool enabled)
    {
        PrimaryButton.Visibility = Shown(!string.IsNullOrEmpty(text));
        PrimaryButton.Content = text;
        PrimaryButton.IsEnabled = enabled;
    }

    // The picked card keeps a check where the others show their chevron, and says so to Narrator.
    private static void ShowChoice(SettingsCard card, bool chosen)
    {
        if (chosen)
        {
            card.ActionIcon = new SymbolIcon(Symbol.Accept);
            AutomationProperties.SetItemStatus(card, Strings.Get("SetupChosen"));
        }
        else
        {
            card.ClearValue(SettingsCard.ActionIconProperty);
            card.ClearValue(AutomationProperties.ItemStatusProperty);
        }
    }

    private void ShowImport()
    {
        if (_panel is { } panel)
        {
            ImportChoose.Visibility = Visibility.Collapsed;
            ImportPanelHost.Visibility = Visibility.Visible;
            ImportPanelHost.Content = panel.Page;
            ShowPrimary(panel.PrimaryText, panel.CanPrimary);
            return;
        }

        ImportChoose.Visibility = Visibility.Visible;
        ImportPanelHost.Visibility = Visibility.Collapsed;
        ImportPanelHost.Content = null;
        if (!Guide.SourcesLoaded && !_loadingSources)
        {
            _loadingSources = true;
            _ = LoadSourcesAsync();
        }

        ImportLooking.Visibility = Shown(!Guide.SourcesLoaded);
        if (Guide.SourcesLoaded && !_sourcesShown)
        {
            FillSources();
        }

        var available = Guide.Sources.Any(source => source.IsAvailable);
        NoSourcesText.Visibility = Shown(Guide.SourcesLoaded && !available);
        SourceList.Visibility = Shown(Guide.SourcesLoaded && Guide.Sources.Count > 0);
        PasswordsBox.Visibility = Shown(available);
        QueriesBox.Visibility = Shown(available);
        if (Guide.SourcesError is not null)
        {
            ShowMessage(Strings.Get("ImportAppSourcesFailed"), InfoBarSeverity.Error);
        }

        var importing = Guide.Queue.Count > 0;
        ShowPrimary(Strings.Get(importing ? "ImportAppAction" : "SetupContinue"), Guide.SourcesLoaded);
    }

    // Entering the step reads each app's counts, off the UI thread through the core.
    private async Task LoadSourcesAsync()
    {
        await Guide.LoadSourcesAsync().ConfigureAwait(true);
        _loadingSources = false;
    }

    private void FillSources()
    {
        _sourcesShown = true;
        SourceList.Items.Clear();
        foreach (var source in Guide.Sources)
        {
            var subtitle = ImportFromAppPanel.SourceText(source);
            var content = new StackPanel();
            content.Children.Add(new TextBlock { Text = source.Name });
            content.Children.Add(new TextBlock
            {
                Text = subtitle,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                TextWrapping = TextWrapping.Wrap,
            });
            var check = new CheckBox
            {
                Content = content,
                IsEnabled = source.IsAvailable,
                IsChecked = Guide.IsTicked(source.App),
            };
            AutomationProperties.SetAutomationId(check, "SetupSource_" + source.App);
            AutomationProperties.SetName(check, source.Name);
            AutomationProperties.SetHelpText(check, subtitle);
            if (ImportFromAppPanel.UnreadableDetail(source) is { } detail)
            {
                ToolTipService.SetToolTip(check, detail);
            }

            var app = source.App;
            check.Checked += (_, _) => Guide.SetTicked(app, true);
            check.Unchecked += (_, _) => Guide.SetTicked(app, false);
            var item = new ListViewItem { Content = check, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(item, source.Name);
            SourceList.Items.Add(item);
        }
    }

    private void StartImport()
    {
        var panel = new ImportFromAppPanel(
            this,
            _workbench,
            _importer,
            Guide.Queue,
            Guide.Sources,
            PasswordsBox.IsChecked == true,
            QueriesBox.IsChecked == true);
        _panel = panel;
        panel.Changed += (_, _) =>
        {
            if (ReferenceEquals(_panel, panel))
            {
                Show();
            }
        };
        panel.Imported += (_, ending) => OnImported(panel, ending);
        panel.Finished += (_, _) =>
        {
            if (ReferenceEquals(_panel, panel))
            {
                DropPanel();
                ShowEndings();
                Guide.Advance();
            }
        };
        MessageBar.IsOpen = false;
        panel.Start();
        Show();
    }

    private void OnImported(ImportFromAppPanel panel, ForeignImportEnding ending)
    {
        var name = panel.CurrentSource?.Name ?? string.Empty;
        _endings.Add((name, ending));
        if (ending.Wrote)
        {
            _imported.Add(name);
        }

        if (ending.Outcome is { } outcome)
        {
            Guide.AddImported(outcome, ending.Source);
            _workbench.NotifyLibraryChanged();
            if (outcome.QueriesAdded > 0)
            {
                _workbench.NotifySavedQueriesChanged();
            }
        }
    }

    // One line per app the guide imported from, the worst outcome deciding the bar's colour.
    private void ShowEndings()
    {
        if (_endings.Count == 0)
        {
            return;
        }

        var severities = _endings.Select(each => ImportFromAppPanel.Severity(each.Ending)).ToList();
        var severity = severities.Contains(InfoBarSeverity.Error) ? InfoBarSeverity.Error
            : severities.Contains(InfoBarSeverity.Warning) ? InfoBarSeverity.Warning
            : severities.Contains(InfoBarSeverity.Success) ? InfoBarSeverity.Success
            : InfoBarSeverity.Informational;
        var lines = _endings.Select(each =>
            Strings.Format("JoinLabelValue", each.App, ImportFromAppPanel.Describe(each.Ending)));
        ShowMessage(string.Join('\n', lines), severity);
    }

    private void ShowMessage(string text, InfoBarSeverity severity)
    {
        if (MessageBar.IsOpen && MessageBar.Message == text && MessageBar.Severity == severity)
        {
            return;
        }

        MessageBar.Severity = severity;
        MessageBar.Message = text;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        MessageBar.IsOpen = false;
        MessageBar.IsOpen = true;
    }

    private void DropPanel()
    {
        if (_panel is not { } panel)
        {
            return;
        }

        _panel = null;
        panel.Cancel();
        _ = DisposeWhenIdleAsync(panel);
    }

    private static async Task DisposeWhenIdleAsync(ImportFromAppPanel panel)
    {
        await panel.WhenIdleAsync().ConfigureAwait(true);
        panel.Dispose();
    }

    // The settings write at once, as Settings writes them; Finish only ends the guide.
    private void ShowOptions()
    {
        if (_optionsShown)
        {
            return;
        }

        _optionsShown = true;
        _filling = true;
        var settings = _workbench.Settings;
        ThemeBox.SelectedIndex = settings.Theme switch
        {
            AppTheme.Light => 0,
            AppTheme.Dark => 1,
            _ => 2,
        };
        SettingsView.FillPresets(ShortcutsBox, settings.ShortcutPreset, _imported.FirstOrDefault());
        VimSwitch.IsOn = settings.VimMode;
        _filling = false;
    }

    private void EndGuide()
    {
        if (_ended)
        {
            return;
        }

        _ended = true;
        var ending = Guide.End();
        DropPanel();
        Ended?.Invoke(this, ending);
    }

    private void OnPrimary(object sender, RoutedEventArgs e)
    {
        switch (Guide.Step)
        {
            case SetupStep.Import when _panel is { } panel:
                panel.Primary();
                break;
            case SetupStep.Import when Guide.Queue.Count > 0:
                StartImport();
                break;
            case SetupStep.Options:
                EndGuide();
                break;
            default:
                Guide.Advance();
                break;
        }
    }

    private void OnSkip(object sender, RoutedEventArgs e) => EndGuide();

    private void OnOtherApp(object sender, RoutedEventArgs e) => Guide.Choose(SetupOrigin.OtherApp);

    // File > Import's own flow: a file picked leaves the guide, and the import selects what it wrote (core 0049).
    private async void OnImportFile(object sender, RoutedEventArgs e) =>
        await _shell.ImportAsync().ConfigureAwait(true);

    private void OnStartNew(object sender, RoutedEventArgs e) => Guide.Choose(SetupOrigin.New);

    private void OnRecordNewConnection(object sender, RoutedEventArgs e)
    {
        Guide.Record(FirstConnectionChoice.NewConnection);
        Guide.Advance();
    }

    private void OnRecordSample(object sender, RoutedEventArgs e)
    {
        Guide.Record(FirstConnectionChoice.Sample);
        Guide.Advance();
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling && ThemeBox.SelectedItem is ComboBoxItem { Tag: string tag })
        {
            var theme = Enum.Parse<AppTheme>(tag);
            _workbench.UpdateSettings(settings => settings with { Theme = theme });
        }
    }

    private void OnShortcutsChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling && ShortcutsBox.SelectedItem is ComboBoxItem { Tag: string id })
        {
            _workbench.UpdateSettings(settings => settings with { ShortcutPreset = id.Length == 0 ? null : id });
        }
    }

    private void OnVimToggled(object sender, RoutedEventArgs e)
    {
        if (!_filling)
        {
            var vim = VimSwitch.IsOn;
            _workbench.UpdateSettings(settings => settings with { VimMode = vim });
        }
    }
}
