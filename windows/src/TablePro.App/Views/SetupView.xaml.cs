using System.Numerics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.UI.ViewManagement;

namespace TablePro.App.Views;

// The setup guide, a page swapped into the window as Settings is (core 0057, windows/docs/decisions/0025 and 0026).
public sealed partial class SetupView : UserControl, IDisposable
{
    private const int StepCount = 4;
    private const double HeroGlyphSize = 48;
    private const double CompactArtSize = 40;
    private const double CardIconSize = 40;
    private const float SlideDistance = 28;
    private static readonly TimeSpan SlideDuration = TimeSpan.FromMilliseconds(250);

    private readonly Workbench _workbench;
    private readonly IShell _shell;
    private readonly IForeignImporter _importer;
    private readonly InstalledAppIcons _icons = new();
    private readonly UISettings _uiSettings = new();
    private readonly List<(string App, ForeignImportEnding Ending)> _endings = [];
    // The apps an import wrote from, by the name the core gives them, which is also their preset's name.
    private readonly List<string> _imported = [];
    private ImportFromAppPanel? _panel;
    private SetupStep? _shownStep;
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
        Describe(OtherAppItem, OtherAppTitle, OtherAppDetail);
        Describe(FileItem, FileTitle, FileDetail);
        Describe(StartItem, StartTitle, StartDetail);
        Describe(NewConnectionItem, NewConnectionTitle, NewConnectionDetail);
        Describe(SampleItem, SampleTitle, SampleDetail);
        AutomationProperties.SetName(ThemeLightTile, ThemeLightLabel.Text);
        AutomationProperties.SetName(ThemeDarkTile, ThemeDarkLabel.Text);
        AutomationProperties.SetName(ThemeSystemTile, ThemeSystemLabel.Text);
        // An item may mark the double tap handled before it reaches the list.
        OriginList.AddHandler(DoubleTappedEvent, new DoubleTappedEventHandler(OnCardDoubleTapped), true);
        FirstConnectionList.AddHandler(DoubleTappedEvent, new DoubleTappedEventHandler(OnCardDoubleTapped), true);
        ElementCompositionPreview.SetIsTranslationEnabled(Column, true);
        Loaded += (_, _) => FocusStep();
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

    private static Visibility Shown(bool shown) => shown ? Visibility.Visible : Visibility.Collapsed;

    private static void Describe(ListViewItem item, TextBlock title, TextBlock detail)
    {
        AutomationProperties.SetName(item, title.Text);
        AutomationProperties.SetHelpText(item, detail.Text);
    }

    private static ListViewItem? ItemAt(DependencyObject? element)
    {
        while (element is not null and not ListViewItem)
        {
            element = VisualTreeHelper.GetParent(element);
        }

        return element as ListViewItem;
    }

    private static void FocusList(ListViewBase list)
    {
        var index = Math.Max(0, list.SelectedIndex);
        if (list.ContainerFromIndex(index) is Control item && item.Focus(FocusState.Programmatic))
        {
            return;
        }

        list.Focus(FocusState.Programmatic);
    }

    private void Show()
    {
        var step = Guide.Step;
        var before = _shownStep;
        _shownStep = step;
        var importing = step == SetupStep.Import;
        OriginList.Visibility = Shown(step == SetupStep.Origin);
        ImportStep.Visibility = Shown(importing && _panel is null);
        ImportPanelHost.Visibility = Shown(importing && _panel is not null);
        FirstConnectionList.Visibility = Shown(step == SetupStep.FirstConnection);
        OptionsStep.Visibility = Shown(step == SetupStep.Options);
        ShowHero(step);
        SkipButton.IsEnabled = _panel is not { IsImporting: true };
        switch (step)
        {
            case SetupStep.Origin:
                ShowOrigin();
                break;
            case SetupStep.Import:
                ShowImport();
                break;
            case SetupStep.FirstConnection:
                ShowFirstConnection();
                ShowPrimary(Strings.Get("SetupContinue"), enabled: true);
                break;
            default:
                ShowOptions();
                ShowPrimary(Strings.Get("SetupFinish_" + Guide.End().GetType().Name), enabled: true);
                break;
        }

        BackChanged?.Invoke(this, EventArgs.Empty);
        if (before != step)
        {
            if (before is { } previous)
            {
                Slide(step > previous);
            }

            FocusStep();
        }
    }

    // Reading or reviewing an app is still step 2, so only the art and the title turn to that app.
    private void ShowHero(SetupStep step)
    {
        var number = (int)step + 1;
        var compact = step == SetupStep.Import && _panel is not null;
        StepLabel.Text = Strings.Format("SetupStepOf", number, StepCount);
        StepDescription.Text = Strings.Get("SetupDescription_" + step);
        StepDescription.Visibility = Shown(!compact);
        ShowArt(step, compact);

        var title = compact ? _panel!.Title : Strings.Get("SetupTitle_" + step);
        if (string.Equals(StepTitle.Text, title, StringComparison.Ordinal))
        {
            return;
        }

        StepTitle.Text = title;
        AutomationProperties.SetName(StepTitle, Strings.Format("SetupStepTitleName", title, number, StepCount));
        // A TextBlock that changes text is not read out by itself, so its live region is raised.
        if (AutomationPeer.ListenerExists(AutomationEvents.LiveRegionChanged))
        {
            FrameworkElementAutomationPeer.CreatePeerForElement(StepTitle)
                .RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }

    private void ShowArt(SetupStep step, bool compact)
    {
        var icon = compact && _panel?.CurrentSource is { } source ? _icons.Loaded(source.App) : null;
        HeroAppIcon.Visibility = Shown(step == SetupStep.Origin);
        HeroSourceIcon.Source = icon;
        HeroSourceIcon.Visibility = Shown(icon is not null);
        HeroGlyph.Visibility = Shown(step != SetupStep.Origin && icon is null);
        HeroGlyph.Width = HeroGlyph.Height = compact ? CompactArtSize : HeroGlyphSize;
        HeroSymbol.Symbol = compact ? Symbol.AllApps : step switch
        {
            SetupStep.Import => Symbol.Import,
            SetupStep.FirstConnection => Symbol.Link,
            _ => Symbol.Setting,
        };
    }

    // Windows' animation effects setting turns this off, as it turns off the system's own.
    private void Slide(bool forward)
    {
        if (!_uiSettings.AnimationsEnabled)
        {
            return;
        }

        var visual = ElementCompositionPreview.GetElementVisual(Column);
        var compositor = visual.Compositor;
        var easing = compositor.CreateCubicBezierEasingFunction(new Vector2(0, 0), new Vector2(0, 1));
        var slide = compositor.CreateVector3KeyFrameAnimation();
        slide.InsertKeyFrame(0, new Vector3(forward ? SlideDistance : -SlideDistance, 0, 0));
        slide.InsertKeyFrame(1, Vector3.Zero, easing);
        slide.Duration = SlideDuration;
        var fade = compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0, 0);
        fade.InsertKeyFrame(1, 1, easing);
        fade.Duration = SlideDuration;
        visual.StartAnimation("Translation", slide);
        visual.StartAnimation("Opacity", fade);
    }

    private void FocusStep()
    {
        ListViewBase? list = Guide.Step switch
        {
            SetupStep.Origin => OriginList,
            SetupStep.Import when _panel is null && SourceList.Items.Count > 0 => SourceList,
            SetupStep.FirstConnection => FirstConnectionList,
            SetupStep.Options => ThemeTiles,
            _ => null,
        };
        if (list is null || !IsLoaded)
        {
            return;
        }

        // The step's items are laid out only after this pass, so the focus waits for it.
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => FocusList(list));
    }

    private void ShowPrimary(string? text, bool enabled)
    {
        PrimaryButton.Visibility = Shown(!string.IsNullOrEmpty(text));
        PrimaryButton.Content = text;
        PrimaryButton.IsEnabled = enabled;
    }

    private void ShowOrigin()
    {
        var selected = Guide.Origin switch
        {
            SetupOrigin.OtherApp => OtherAppItem,
            SetupOrigin.File => FileItem,
            _ => StartItem,
        };
        // Only the probe moves the selection from under the focused card, and the focus goes with it.
        var follow = OriginList.SelectedItem is not null
            && !ReferenceEquals(OriginList.SelectedItem, selected)
            && OriginHasFocus();
        _filling = true;
        try
        {
            OriginList.SelectedItem = selected;
        }
        finally
        {
            _filling = false;
        }

        if (Guide.Found.Count > 0)
        {
            OtherAppDetail.Text = Strings.Format("SetupFoundApps", Strings.ListAnd(Guide.Found));
            Describe(OtherAppItem, OtherAppTitle, OtherAppDetail);
        }

        if (follow)
        {
            FocusList(OriginList);
        }

        ShowPrimary(Strings.Get("SetupContinue"), enabled: true);
    }

    private bool OriginHasFocus() =>
        XamlRoot is { } root
        && ItemAt(FocusManager.GetFocusedElement(root) as DependencyObject) is { } item
        && OriginList.IndexFromContainer(item) >= 0;

    // The recorded choice is the selected card, which says so to Narrator.
    private void ShowFirstConnection()
    {
        var chosen = Guide.Recorded switch
        {
            FirstConnectionChoice.NewConnection => NewConnectionItem,
            FirstConnectionChoice.Sample => SampleItem,
            _ => null,
        };
        _filling = true;
        try
        {
            FirstConnectionList.SelectedItem = chosen;
        }
        finally
        {
            _filling = false;
        }

        foreach (var item in new[] { NewConnectionItem, SampleItem })
        {
            if (ReferenceEquals(item, chosen))
            {
                AutomationProperties.SetItemStatus(item, Strings.Get("SetupChosen"));
            }
            else
            {
                item.ClearValue(AutomationProperties.ItemStatusProperty);
            }
        }
    }

    private void ShowImport()
    {
        if (_panel is { } panel)
        {
            ImportPanelHost.Content = panel.Page;
            ShowPrimary(panel.PrimaryText, panel.CanPrimary);
            return;
        }

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

        var cards = SourceList.Items.Count;
        SourceList.Visibility = Shown(cards > 0);
        NotFoundText.Visibility = Shown(NotFoundText.Text.Length > 0);
        NoSources.Visibility = Shown(Guide.SourcesLoaded && cards == 0 && Guide.SourcesError is null);
        ImportOptions.Visibility = Shown(Guide.Sources.Any(source => source.IsAvailable));
        if (Guide.SourcesError is not null)
        {
            ShowMessage(Strings.Get("ImportAppSourcesFailed"), InfoBarSeverity.Error);
        }

        ShowPrimary(ImportPrimaryText(), Guide.SourcesLoaded);
    }

    // An app read from a picked file has no count, so a queue of only those says Import.
    private string ImportPrimaryText()
    {
        var queue = Guide.Queue;
        if (queue.Count == 0)
        {
            return Strings.Get("SetupContinue");
        }

        var connections = queue.Sum(source => source.Connections);
        return connections > 0
            ? Strings.Plural("SetupImportConnections", connections, connections)
            : Strings.Get("ImportAppAction");
    }

    // Entering the step reads each app's counts, off the UI thread through the core.
    private async Task LoadSourcesAsync()
    {
        await Guide.LoadSourcesAsync().ConfigureAwait(true);
        _loadingSources = false;
    }

    // An app that cannot be read stays a card, so no count hides its reason; one not on this PC is only named.
    private void FillSources()
    {
        _sourcesShown = true;
        var missing = new List<string>();
        _filling = true;
        try
        {
            SourceList.Items.Clear();
            foreach (var source in Guide.Sources)
            {
                if (ForeignImportForm.NoteFor(source) == ForeignSourceNote.NotFound)
                {
                    missing.Add(source.Name);
                    continue;
                }

                var item = SourceCard(source);
                SourceList.Items.Add(item);
                if (Guide.IsTicked(source.App))
                {
                    SourceList.SelectedItems.Add(item);
                }
            }
        }
        finally
        {
            _filling = false;
        }

        NotFoundText.Text = missing.Count > 0 ? Strings.Format("SetupNotFound", Strings.List(missing)) : string.Empty;
        if (Guide.Step == SetupStep.Import && SourceList.Items.Count > 0)
        {
            FocusStep();
        }
    }

    private ListViewItem SourceCard(ForeignSource source)
    {
        var detail = ImportFromAppPanel.SourceText(source);
        var unreadable = ImportFromAppPanel.UnreadableDetail(source);

        var glyph = new Viewbox { Width = 24, Height = 24, Child = new SymbolIcon(Symbol.AllApps) };
        var image = new Image { Width = CardIconSize, Height = CardIconSize, Visibility = Visibility.Collapsed };
        AutomationProperties.SetAccessibilityView(image, AccessibilityView.Raw);
        var art = new Grid();
        art.Children.Add(glyph);
        art.Children.Add(image);

        var detailText = new TextBlock { Text = detail, Style = (Style)Resources["SetupCardDetailStyle"] };
        UIElement line = detailText;
        if (unreadable is not null)
        {
            var caution = new FontIcon
            {
                Style = (Style)Resources["SetupCautionIconStyle"],
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
            };
            ToolTipService.SetToolTip(caution, unreadable);
            // A grid, not a horizontal StackPanel, so the reason wraps beside the glyph.
            var warning = new Grid { ColumnSpacing = 6 };
            warning.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            warning.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            warning.Children.Add(caution);
            Grid.SetColumn(detailText, 1);
            warning.Children.Add(detailText);
            line = warning;
        }

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = source.Name, Style = (Style)Resources["SetupCardTitleStyle"] });
        text.Children.Add(line);

        var content = new Grid { ColumnSpacing = 12 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(CardIconSize) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(art);
        Grid.SetColumn(text, 1);
        content.Children.Add(text);

        var item = new ListViewItem
        {
            Content = content,
            IsEnabled = source.IsAvailable,
            Style = (Style)Resources["SetupCardItemStyle"],
            Tag = source.App,
        };
        AutomationProperties.SetAutomationId(item, "SetupSource_" + source.App);
        AutomationProperties.SetName(item, source.Name);
        AutomationProperties.SetHelpText(item, detail);
        if (unreadable is not null)
        {
            ToolTipService.SetToolTip(item, unreadable);
        }

        _ = ShowIconAsync(source, image, glyph);
        return item;
    }

    private async Task ShowIconAsync(ForeignSource source, Image image, UIElement glyph)
    {
        var pixels = (int)Math.Ceiling(CardIconSize * (XamlRoot?.RasterizationScale ?? 1));
        if (await _icons.GetAsync(source, pixels).ConfigureAwait(true) is not { } icon)
        {
            return;
        }

        image.Source = icon;
        image.Visibility = Visibility.Visible;
        glyph.Visibility = Visibility.Collapsed;
        if (_panel?.CurrentSource?.App == source.App)
        {
            ShowHero(Guide.Step);
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
        HideMessage();
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
        MessageBar.Visibility = Visibility.Visible;
    }

    private void HideMessage()
    {
        MessageBar.IsOpen = false;
        MessageBar.Visibility = Visibility.Collapsed;
    }

    // A closed InfoBar keeps its place in the column, so it leaves the layout as it closes.
    private void OnMessageClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (!MessageBar.IsOpen)
        {
            MessageBar.Visibility = Visibility.Collapsed;
        }
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
        try
        {
            var settings = _workbench.Settings;
            ThemeTiles.SelectedItem = settings.Theme switch
            {
                AppTheme.Light => ThemeLightTile,
                AppTheme.Dark => ThemeDarkTile,
                _ => ThemeSystemTile,
            };
            SettingsView.FillPresets(ShortcutsBox, settings.ShortcutPreset, _imported.FirstOrDefault());
            VimSwitch.IsOn = settings.VimMode;
        }
        finally
        {
            _filling = false;
        }
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

    private async Task PrimaryAsync()
    {
        switch (Guide.Step)
        {
            // File > Import's own flow: a picked file leaves the guide and selects what it wrote (core 0057).
            case SetupStep.Origin when Guide.Origin == SetupOrigin.File:
                await _shell.ImportAsync().ConfigureAwait(true);
                break;
            case SetupStep.Origin:
                Guide.Choose(Guide.Origin);
                break;
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

    private async void OnPrimary(object sender, RoutedEventArgs e) => await PrimaryAsync().ConfigureAwait(true);

    private void OnSkip(object sender, RoutedEventArgs e) => EndGuide();

    private async void OnCardDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (ItemAt(e.OriginalSource as DependencyObject) is { IsSelected: true } && PrimaryButton.IsEnabled)
        {
            await PrimaryAsync().ConfigureAwait(true);
        }
    }

    private void OnOriginChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling)
        {
            return;
        }

        if (OriginList.SelectedItem is ListViewItem { Tag: string tag })
        {
            Guide.Select(Enum.Parse<SetupOrigin>(tag));
        }
        else
        {
            // Continue always has a card to act on, so a card cannot be unselected.
            ShowOrigin();
        }
    }

    // Selecting records the choice at once, so Skip runs it too.
    private void OnFirstConnectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling)
        {
            return;
        }

        switch ((FirstConnectionList.SelectedItem as ListViewItem)?.Tag)
        {
            case "NewConnection":
                Guide.Record(FirstConnectionChoice.NewConnection);
                break;
            case "Sample":
                Guide.Record(FirstConnectionChoice.Sample);
                break;
            default:
                // A choice once recorded cannot be taken back, so the card stays selected.
                ShowFirstConnection();
                break;
        }
    }

    private void OnSourcesChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling)
        {
            return;
        }

        foreach (var item in e.RemovedItems.OfType<ListViewItem>())
        {
            if (item.Tag is ForeignApp app)
            {
                Guide.SetTicked(app, false);
            }
        }

        foreach (var item in e.AddedItems.OfType<ListViewItem>())
        {
            if (item.Tag is ForeignApp app)
            {
                Guide.SetTicked(app, true);
            }
        }
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling && ThemeTiles.SelectedItem is GridViewItem { Tag: string tag })
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
