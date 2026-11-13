using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.Graphics;
using Windows.System;

namespace TablePro.App.ConnectionForm;

internal sealed record FormResult(SavedConnection Saved, bool Connect, bool ChangesConnect);

// A separate window lets the form stay open while the workspace remains usable.
public sealed partial class ConnectionFormWindow : Window
{
    private static readonly string[] Colors = ["", "blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"];
    private static readonly MaskStyle[] MaskStyles = [MaskStyle.Full, MaskStyle.LastFour, MaskStyle.Email, MaskStyle.Hash, MaskStyle.Null];

    private readonly Workbench _workbench;
    // Native AOT trims OverlappedPresenter's wrapper, so AppWindow.Presenter reads back as its base type.
    private readonly OverlappedPresenter _presenter = OverlappedPresenter.Create();
    private readonly bool _isNew;
    private readonly SavedConnection? _existing;
    private ConnectionDraft? _draft;
    private DatabaseEngine? _engine;
    private bool _createFile;
    private IReadOnlyList<ConnectionGroup> _groups = [];
    private readonly Guid? _groupToSelect;
    private CancellationTokenSource? _testing;
    private bool _busy;
    private bool _fillingTls;
    private TlsRemedy? _remedy;

    internal ConnectionFormWindow(Workbench workbench, Window owner, SavedConnection? existing)
    {
        _workbench = workbench;
        _isNew = existing is null;
        _existing = existing;
        Key = Keys(existing?.Id);
        InitializeComponent();
        EngineGrid.ContainerContentChanging += OnEngineContainerChanging;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(FormTitleBar);
        Title = Strings.Get(_isNew ? "NewConnectionTitle" : "EditConnectionTitle");
        FormTitleBar.Title = Title;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop();
        }

        WindowInterop.SetOwner(this, owner);
        Place(owner);
        Themes.Apply(this, workbench.Settings.Theme);
        FillEngines(string.Empty);
        FillColors();
        Closed += (_, _) => _testing?.Cancel();
        _groupToSelect = existing?.GroupId;
        if (existing is not null && workbench.Engine(existing.EngineId) is { } engine)
        {
            ShowDetails(engine, ConnectionDraft.From(existing, engine));
        }
        else
        {
            ShowChooser();
        }

        _ = LoadGroupsAsync();
    }

    internal event EventHandler<FormResult>? Completed;

    internal string Key { get; }

    internal static string Keys(Guid? id) => id?.ToString() ?? "new";

    private void Place(Window owner)
    {
        var scale = WindowInterop.Scale(owner);
        var size = new SizeInt32((int)(760 * scale), (int)(780 * scale));
        var center = owner.AppWindow.Position;
        var ownerSize = owner.AppWindow.Size;
        AppWindow.MoveAndResize(new RectInt32(
            center.X + Math.Max(0, (ownerSize.Width - size.Width) / 2),
            center.Y + Math.Max(0, (ownerSize.Height - size.Height) / 2),
            size.Width,
            size.Height));
        _presenter.IsMinimizable = false;
        _presenter.PreferredMinimumWidth = (int)(560 * scale);
        _presenter.PreferredMinimumHeight = (int)(480 * scale);
        AppWindow.SetPresenter(_presenter);
    }

    // By family, as the macOS app lists them.
    private void FillEngines(string query)
    {
        EngineSource.Source = EngineCatalog.Sections(_workbench.Engines, query)
            .Select(section => new EngineGroup(
                Strings.Get("EngineGroup_" + section.Category),
                section.Engines.Select(Choice).ToList()))
            .ToList();
    }

    private static EngineChoice Choice(DatabaseEngine engine) => new(
        engine,
        engine.DefaultPort is { } port
            ? Strings.Format("EngineDefaultPort", port)
            : string.Join(", ", engine.FileSuffixes.Select(suffix => "." + suffix)));

    private void FillColors()
    {
        ColorBox.Items.Clear();
        foreach (var color in Colors)
        {
            ColorBox.Items.Add(new ComboBoxItem
            {
                Content = Strings.Get(color.Length == 0 ? "ColorNone" : "Color_" + color),
                Tag = color,
            });
        }
    }

    private async Task LoadGroupsAsync()
    {
        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
            _groups = snapshot.Groups;
        }
        catch (TableProException)
        {
            _groups = [];
        }

        var byId = _groups.ToDictionary(group => group.Id);
        GroupBox.Items.Clear();
        GroupBox.Items.Add(new ComboBoxItem { Content = Strings.Get("GroupNone"), Tag = null });
        foreach (var group in _groups)
        {
            GroupBox.Items.Add(new ComboBoxItem { Content = LibraryTree.GroupPath(group.Id, byId), Tag = group.Id });
        }

        var selected = _draft?.GroupId ?? _groupToSelect;
        GroupBox.SelectedItem = GroupBox.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag is Guid id && id == selected)
            ?? GroupBox.Items[0];
    }

    private void ShowChooser()
    {
        ChooserPage.Visibility = Visibility.Visible;
        DetailsPage.Visibility = Visibility.Collapsed;
        Footer.Visibility = Visibility.Collapsed;
        FormTitleBar.IsBackButtonVisible = false;
        EngineSearch.Focus(FocusState.Programmatic);
    }

    private void ShowDetails(DatabaseEngine engine, ConnectionDraft draft)
    {
        _engine = engine;
        _draft = draft;
        _createFile = false;
        ChooserPage.Visibility = Visibility.Collapsed;
        DetailsPage.Visibility = Visibility.Visible;
        Footer.Visibility = Visibility.Visible;
        FormTitleBar.IsBackButtonVisible = _isNew;
        ChangeEngineButton.Visibility = _isNew ? Visibility.Visible : Visibility.Collapsed;
        EngineText.Text = engine.DisplayName;
        EngineIcon.Content = EngineIcons.Glyph(engine.Id);
        ConnectButton.Style = _isNew ? (Style)Application.Current.Resources["AccentButtonStyle"] : null;
        SaveButton.Style = _isNew ? null : (Style)Application.Current.Resources["AccentButtonStyle"];

        NetworkFields.Visibility = draft.IsFileEngine ? Visibility.Collapsed : Visibility.Visible;
        FileFields.Visibility = draft.IsFileEngine ? Visibility.Visible : Visibility.Collapsed;
        SshExpander.Visibility = draft.IsFileEngine ? Visibility.Collapsed : Visibility.Visible;
        TlsExpander.Visibility = draft.IsFileEngine ? Visibility.Collapsed : Visibility.Visible;

        NameBox.Text = draft.Name;
        HostBox.Text = draft.Host;
        PortBox.Text = draft.Port;
        UserBox.Text = draft.UserName;
        PasswordInput.Password = draft.Password;
        PasswordInput.PlaceholderText = draft.IsNew ? string.Empty : Strings.Get("PasswordKeptPlaceholder");
        DatabaseBox.Text = draft.Database;
        FileBox.Text = draft.IsFileEngine ? draft.Database : string.Empty;
        SshSwitch.IsOn = draft.UseSsh;
        SshHostBox.Text = draft.SshHost;
        SshPortBox.Text = draft.SshPort;
        SshUserBox.Text = draft.SshUserName;
        SshAuthBox.SelectedIndex = (int)draft.SshAuth;
        SshKeyBox.Text = draft.SshKeyPath;
        SshPasswordInput.Password = string.Empty;
        AuthBox.Visibility = engine.SupportsIntegratedAuth ? Visibility.Visible : Visibility.Collapsed;
        AuthBox.SelectedIndex = draft.IntegratedAuth ? 1 : 0;
        FillTlsModes(engine, draft.TlsMode);
        CaFileBox.Text = draft.CaFile;
        ServerNameBox.Text = draft.ServerName;
        ClientCertificateBox.Text = draft.ClientCertificate;
        ClientKeyBox.Text = draft.ClientKey;
        SafeModeBox.SelectedIndex = (int)draft.SafeMode;
        TimeoutBox.Text = draft.Timeout;
        FillMaskingRules(draft);
        ColorBox.SelectedIndex = Math.Max(0, Array.IndexOf(Colors, draft.Color ?? string.Empty));
        NameBox.PlaceholderText = draft.SuggestedName();
        ClearErrors();
        SetStatus(string.Empty, null);
        UpdateSsh();
        UpdateAuthentication();
        UpdateTls();
        UpdateSummaries();
        (draft.IsFileEngine ? (Control)FileBox : HostBox).Focus(FocusState.Programmatic);
    }

    private ConnectionDraft ReadDraft()
    {
        var draft = _draft!;
        draft.Name = NameBox.Text;
        if (draft.IsFileEngine)
        {
            draft.Database = FileBox.Text;
        }
        else
        {
            draft.Host = HostBox.Text;
            draft.Port = PortBox.Text;
            draft.UserName = UserBox.Text;
            draft.IntegratedAuth = AuthBox.SelectedIndex == 1;
            draft.Password = PasswordInput.Password;
            draft.Database = DatabaseBox.Text;
            draft.UseSsh = SshSwitch.IsOn;
            draft.SshHost = SshHostBox.Text;
            draft.SshPort = SshPortBox.Text;
            draft.SshUserName = SshUserBox.Text;
            draft.SshAuth = (SshAuthMethod)Math.Max(0, SshAuthBox.SelectedIndex);
            draft.SshKeyPath = SshKeyBox.Text;
            draft.SshPassword = SshPasswordInput.Password;
            draft.TlsMode = SelectedTlsMode;
            draft.CaFile = CaFileBox.Text;
            draft.ServerName = ServerNameBox.Text;
            draft.ClientCertificate = ClientCertificateBox.Text;
            draft.ClientKey = ClientKeyBox.Text;
        }

        draft.SafeMode = (SafeMode)Math.Max(0, SafeModeBox.SelectedIndex);
        draft.Timeout = TimeoutBox.Text;
        draft.Color = ColorBox.SelectedItem is ComboBoxItem { Tag: string color } && color.Length > 0 ? color : null;
        draft.GroupId = GroupBox.SelectedItem is ComboBoxItem { Tag: Guid group } ? group : null;
        return draft;
    }

    private bool Validate()
    {
        ClearErrors();
        var draft = ReadDraft();
        var errors = draft.Validate();
        if (errors.Count == 0)
        {
            return true;
        }

        Control? first = null;
        foreach (var error in errors)
        {
            var field = Field(error.Field);
            SetError(field, Message(error));
            first ??= field;
            if (error.Field is FormField.SshHost or FormField.SshPort or FormField.SshKey)
            {
                SshExpander.IsExpanded = true;
            }
            else if (error.Field is FormField.ClientKey)
            {
                TlsExpander.IsExpanded = true;
            }
            else if (error.Field is FormField.Timeout)
            {
                OptionsExpander.IsExpanded = true;
            }
        }

        SetStatus(Strings.Get("FormHasErrors"), false);
        first?.Focus(FocusState.Programmatic);
        return false;
    }

    private TextBox Field(FormField field) => field switch
    {
        FormField.Host => HostBox,
        FormField.Port => PortBox,
        FormField.File => FileBox,
        FormField.SshHost => SshHostBox,
        FormField.SshPort => SshPortBox,
        FormField.SshKey => SshKeyBox,
        FormField.ClientKey => ClientKeyBox,
        _ => TimeoutBox,
    };

    private static string Message(FieldError error) => (error.Field, error.Problem) switch
    {
        (FormField.ClientKey, _) => Strings.Get("FieldClientPair"),
        (_, FieldProblem.Required) => Strings.Get("FieldRequired"),
        (_, FieldProblem.NotANumber) => Strings.Get("FieldNotANumber"),
        (_, FieldProblem.NotAbsolute) => Strings.Get("FieldNotAbsolute"),
        (FormField.Timeout, FieldProblem.OutOfRange) => Strings.Get("FieldTimeoutRange"),
        _ => Strings.Get("FieldPortRange"),
    };

    // The reason sits under the field, where the guidance for input errors puts it.
    private void SetError(Control field, string message)
    {
        var text = new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Root.Resources["FormErrorTextStyle"],
        };
        switch (field)
        {
            case TextBox box:
                box.Description = text;
                break;
            case PasswordBox box:
                box.Description = text;
                break;
            default:
                break;
        }

        Microsoft.UI.Xaml.Automation.AutomationProperties.SetFullDescription(field, message);
    }

    private void ClearErrors()
    {
        foreach (var box in new[] { HostBox, PortBox, FileBox, SshHostBox, SshPortBox, SshKeyBox, ClientKeyBox, TimeoutBox })
        {
            box.Description = null;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetFullDescription(box, string.Empty);
        }
    }

    private void SetStatus(string text, bool? success)
    {
        _remedy = null;
        TlsRemedyButton.Visibility = Visibility.Collapsed;
        StatusText.Text = text;
        StatusText.Style = (Style)Root.Resources[success switch
        {
            true => "FormSuccessTextStyle",
            false => "FormErrorTextStyle",
            null => "FormNeutralTextStyle",
        }];
        ToolTipService.SetToolTip(StatusText, string.IsNullOrEmpty(text) ? null : text);
    }

    private void SetFailure(CoreError error)
    {
        var message = error.TlsFailure is { } failure
            ? Strings.Get("TlsFailure_" + failure)
            : string.Empty;
        SetStatus(string.IsNullOrEmpty(message) ? Strings.Error(error) : message, false);
        _remedy = error.TlsFailure is { } tlsFailure
            ? TlsRemedies.For(tlsFailure, _engine?.ShowsServerName(SshSwitch.IsOn) == true)
            : null;
        if (_remedy is { } remedy)
        {
            TlsRemedyButton.Content = Strings.Get("TlsRemedy_" + remedy);
            TlsRemedyButton.Visibility = Visibility.Visible;
        }
    }

    private void OnTlsRemedy(object sender, RoutedEventArgs e)
    {
        TlsExpander.IsExpanded = true;
        Control target = _remedy switch
        {
            TlsRemedy.ChooseCaCertificate => CaFileBox,
            TlsRemedy.SetServerName => ServerNameBox,
            _ => TlsModeBox,
        };
        target.StartBringIntoView();
        target.Focus(FocusState.Programmatic);
        TlsModeBox.IsDropDownOpen = _remedy is TlsRemedy.ChangeEncryption;
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        TestButton.IsEnabled = !busy;
        ConnectButton.IsEnabled = !busy;
        SaveButton.IsEnabled = !busy;
        TestRing.IsActive = busy;
    }

    private TlsMode SelectedTlsMode => TlsModeBox.SelectedItem is ComboBoxItem { Tag: TlsMode mode }
        ? mode
        : TlsMode.Disable;

    private void FillTlsModes(DatabaseEngine engine, TlsMode selected)
    {
        _fillingTls = true;
        TlsModeBox.Items.Clear();
        foreach (var mode in engine.SupportedTlsModes)
        {
            var item = new ComboBoxItem { Content = Strings.Get("TlsMode_" + mode), Tag = mode };
            TlsModeBox.Items.Add(item);
            if (mode == selected)
            {
                TlsModeBox.SelectedItem = item;
            }
        }

        if (TlsModeBox.SelectedItem is null && TlsModeBox.Items.Count > 0)
        {
            TlsModeBox.SelectedIndex = 0;
        }

        _fillingTls = false;
    }

    private void OnPortChanged(object sender, TextChangedEventArgs e)
    {
        if (_draft is null || _engine is null || _fillingTls)
        {
            return;
        }

        _draft.Port = PortBox.Text;
        _draft.FollowTlsDefault(_engine);
        if (SelectedTlsMode != _draft.TlsMode)
        {
            FillTlsModes(_engine, _draft.TlsMode);
            UpdateTls();
            UpdateSummaries();
        }
    }

    private void UpdateAuthentication()
    {
        var visibility = AuthBox.SelectedIndex == 1 ? Visibility.Collapsed : Visibility.Visible;
        UserBox.Visibility = visibility;
        PasswordInput.Visibility = visibility;
    }

    private void UpdateTls()
    {
        var verifies = SelectedTlsMode is TlsMode.VerifyFull or TlsMode.Strict;
        CaFileCard.Visibility = verifies ? Visibility.Visible : Visibility.Collapsed;
        var serverName = verifies && _engine?.ShowsServerName(SshSwitch.IsOn) == true;
        ServerNameCard.Visibility = serverName ? Visibility.Visible : Visibility.Collapsed;
        var clientIdentity = _engine?.SupportsClientIdentity == true && SelectedTlsMode != TlsMode.Disable;
        ClientCertificateCard.Visibility = clientIdentity ? Visibility.Visible : Visibility.Collapsed;
        ClientKeyCard.Visibility = clientIdentity ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnAuthChanged(object sender, SelectionChangedEventArgs e) => UpdateAuthentication();

    private void OnTlsChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_draft is not null)
        {
            // A fill selects the draft's own mode, so only a different one is the user's pick.
            if (!_fillingTls && SelectedTlsMode != _draft.TlsMode)
            {
                _draft.TlsMode = SelectedTlsMode;
                _draft.TlsModeChosen = true;
            }

            UpdateTls();
            UpdateSummaries();
        }
    }

    private void UpdateSsh()
    {
        var method = (SshAuthMethod)Math.Max(0, SshAuthBox.SelectedIndex);
        SshKeyCard.Visibility = method == SshAuthMethod.PrivateKey ? Visibility.Visible : Visibility.Collapsed;
        SshPasswordCard.Visibility = method == SshAuthMethod.Password ? Visibility.Visible : Visibility.Collapsed;
    }

    // Each section says what it holds while folded.
    private void UpdateSummaries()
    {
        SshExpander.Description = SshSwitch.IsOn && !string.IsNullOrWhiteSpace(SshHostBox.Text)
            ? string.IsNullOrWhiteSpace(SshUserBox.Text) ? SshHostBox.Text.Trim() : $"{SshUserBox.Text.Trim()}@{SshHostBox.Text.Trim()}"
            : Strings.Get(SshSwitch.IsOn ? "SshOnSummary" : "SshOffSummary");
        TlsExpander.Description = (TlsModeBox.SelectedItem as ComboBoxItem)?.Content as string ?? string.Empty;
        var safeMode = (SafeModeBox.SelectedItem as ComboBoxItem)?.Content as string ?? string.Empty;
        var options = string.IsNullOrWhiteSpace(TimeoutBox.Text)
            ? Strings.Format("OptionsSummary", safeMode)
            : Strings.Format("OptionsSummaryTimeout", safeMode, TimeoutBox.Text.Trim());
        var rules = _draft?.MaskingRules.Count ?? 0;
        OptionsExpander.Description = rules switch
        {
            0 => options,
            1 => Strings.Format("OptionsSummaryMaskingOne", options),
            _ => Strings.Format("OptionsSummaryMaskingMany", options, rules),
        };
        var color = (ColorBox.SelectedItem as ComboBoxItem)?.Content as string ?? string.Empty;
        var group = (GroupBox.SelectedItem as ComboBoxItem)?.Content as string ?? string.Empty;
        AppearanceExpander.Description = Strings.Format("AppearanceSummary", color, group);
    }

    private void OnSummaryChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_draft is not null)
        {
            UpdateSummaries();
        }
    }

    private void OnSshToggled(object sender, RoutedEventArgs e)
    {
        UpdateTls();
        UpdateSummaries();
        if (SshSwitch.IsOn)
        {
            SshExpander.IsExpanded = true;
        }
    }

    private void OnSshAuthChanged(object sender, SelectionChangedEventArgs e) => UpdateSsh();

    // Each row edits its rule in the draft at once, so a save reads the rows in their order.
    private void FillMaskingRules(ConnectionDraft draft)
    {
        MaskingRulesPanel.Children.Clear();
        foreach (var rule in draft.MaskingRules)
        {
            MaskingRulesPanel.Children.Add(MaskingRow(draft, rule));
        }

        MaskingRulesPanel.Visibility = draft.MaskingRules.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NameMaskingRows();
    }

    // Each row's controls name their rule's place, so a screen reader tells the rows apart.
    private void NameMaskingRows()
    {
        for (var index = 0; index < MaskingRulesPanel.Children.Count; index++)
        {
            if (MaskingRulesPanel.Children[index] is not Grid row || row.Children.Count < 4)
            {
                continue;
            }

            var number = index + 1;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row.Children[0], Strings.Format("MaskingTargetName", number));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row.Children[1], Strings.Format("MaskingPatternName", number));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row.Children[2], Strings.Format("MaskingStyleName", number));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row.Children[3], Strings.Format("RemoveMaskingRuleName", number));
        }
    }

    private Grid MaskingRow(ConnectionDraft draft, MaskingRuleDraft rule)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var pattern = new TextBox
        {
            Text = rule.Pattern,
            MinWidth = 160,
            PlaceholderText = Placeholder(rule.Target),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(pattern, "MaskingPattern");
        pattern.TextChanged += (_, _) => rule.Pattern = pattern.Text;

        var target = new ComboBox { MinWidth = 110 };
        foreach (var each in new[] { MaskTarget.Column, MaskTarget.Type })
        {
            target.Items.Add(new ComboBoxItem { Content = Strings.Get("MaskTarget_" + each), Tag = each });
        }

        target.SelectedIndex = rule.Target == MaskTarget.Type ? 1 : 0;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(target, "MaskingTarget");
        target.SelectionChanged += (_, _) =>
        {
            rule.Target = target.SelectedItem is ComboBoxItem { Tag: MaskTarget picked } ? picked : MaskTarget.Column;
            pattern.PlaceholderText = Placeholder(rule.Target);
        };

        var style = new ComboBox { MinWidth = 150 };
        foreach (var each in MaskStyles)
        {
            style.Items.Add(new ComboBoxItem { Content = Strings.Get("MaskStyle_" + each), Tag = each });
        }

        style.SelectedIndex = Math.Max(0, Array.IndexOf(MaskStyles, rule.Style));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(style, "MaskingStyle");
        style.SelectionChanged += (_, _) =>
            rule.Style = style.SelectedItem is ComboBoxItem { Tag: MaskStyle picked } ? picked : MaskStyle.Full;

        var remove = new Button { Content = new SymbolIcon(Symbol.Delete) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(remove, "RemoveMaskingRule");
        ToolTipService.SetToolTip(remove, Strings.Get("RemoveMaskingRule"));
        remove.Click += (_, _) =>
        {
            var index = MaskingRulesPanel.Children.IndexOf(row);
            draft.MaskingRules.Remove(rule);
            MaskingRulesPanel.Children.Remove(row);
            MaskingRulesPanel.Visibility = draft.MaskingRules.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            NameMaskingRows();
            UpdateSummaries();
            // Focus stays in the list, on the row that took this one's place, else on Add rule.
            var next = MaskingRulesPanel.Children.Count > 0
                ? ((Grid)MaskingRulesPanel.Children[Math.Min(index, MaskingRulesPanel.Children.Count - 1)]).Children[1]
                : AddMaskingRuleButton;
            ((Control)next).Focus(FocusState.Programmatic);
        };

        row.Children.Add(target);
        Grid.SetColumn(pattern, 1);
        row.Children.Add(pattern);
        Grid.SetColumn(style, 2);
        row.Children.Add(style);
        Grid.SetColumn(remove, 3);
        row.Children.Add(remove);
        return row;
    }

    private static string Placeholder(MaskTarget target) => target == MaskTarget.Type ? "uuid" : "*.email";

    private void OnAddMaskingRule(object sender, RoutedEventArgs e)
    {
        if (_draft is not { } draft)
        {
            return;
        }

        var rule = new MaskingRuleDraft();
        draft.MaskingRules.Add(rule);
        var row = MaskingRow(draft, rule);
        MaskingRulesPanel.Children.Add(row);
        MaskingRulesPanel.Visibility = Visibility.Visible;
        NameMaskingRows();
        UpdateSummaries();
        ((Control)row.Children[1]).Focus(FocusState.Programmatic);
    }

    private void OnEngineSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) =>
        FillEngines(sender.Text);

    // A GridView item's name comes from its container, not from the template inside it.
    private static void OnEngineContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is EngineChoice choice)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, choice.AccessibleName);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(args.ItemContainer, "Engine_" + choice.Engine.Id);
        }
    }

    private void OnEngineClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is EngineChoice choice)
        {
            ShowDetails(choice.Engine, ConnectionDraft.New(choice.Engine));
        }
    }

    private void OnUrlFlyoutOpened(object sender, object e)
    {
        UrlBox.Description = null;
        UrlBox.Focus(FocusState.Programmatic);
    }

    private void OnUrlKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            ContinueFromUrl();
        }
    }

    private void OnUrlContinue(object sender, RoutedEventArgs e) => ContinueFromUrl();

    private void ContinueFromUrl()
    {
        try
        {
            var parsed = TableProCore.ParseConnectionUrl(UrlBox.Text);
            var engine = _workbench.Engine(parsed.EngineId);
            if (engine is null)
            {
                UrlBox.Description = Strings.Get("Error_url_unknown_scheme");
                return;
            }

            var draft = ConnectionDraft.New(engine);
            draft.Apply(parsed, engine);
            if (draft.IsFileEngine)
            {
                draft.Database = parsed.Database;
            }

            UrlFlyout.Hide();
            ShowDetails(engine, draft);
        }
        catch (TableProException exception)
        {
            UrlBox.Description = Strings.Error(exception.Error);
        }
    }

    private void OnChangeEngine(object sender, RoutedEventArgs e) => ShowChooser();

    private void OnBack(TitleBar sender, object args) => ShowChooser();

    private void OnEscape(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (UrlFlyout.IsOpen)
        {
            return;
        }

        args.Handled = true;
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private async void OnBrowseFile(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var suffix in _engine?.FileSuffixes ?? [])
        {
            picker.FileTypeFilter.Add("." + suffix);
        }

        picker.FileTypeFilter.Add("*");
        var result = await picker.PickSingleFileAsync();
        if (result is not null)
        {
            FileBox.Text = result.Path;
            _createFile = false;
            SetStatus(string.Empty, null);
        }
    }

    private async void OnNewFile(object sender, RoutedEventArgs e)
    {
        var suffixes = _engine?.FileSuffixes ?? [];
        var picker = new FileSavePicker(AppWindow.Id)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = Strings.Get("NewDatabaseFileName"),
        };
        if (suffixes.Count > 0)
        {
            picker.FileTypeChoices.Add(_engine!.DisplayName, suffixes.Select(suffix => "." + suffix).ToList());
        }

        var result = await picker.PickSaveFileAsync();
        if (result is not null)
        {
            FileBox.Text = result.Path;
            _createFile = true;
            SetStatus(Strings.Get("NewFileOnConnect"), null);
        }
    }

    private async void OnBrowseKey(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add("*");
        var result = await picker.PickSingleFileAsync();
        if (result is not null)
        {
            SshKeyBox.Text = result.Path;
        }
    }

    private async void OnBrowseCertificate(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        foreach (var suffix in new[] { ".pem", ".crt", ".cer", ".key", "*" })
        {
            picker.FileTypeFilter.Add(suffix);
        }

        var result = await picker.PickSingleFileAsync();
        if (result is not null && sender is FrameworkElement { Tag: string target } && Root.FindName(target) is TextBox box)
        {
            box.Text = result.Path;
        }
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        if (_busy || !Validate())
        {
            return;
        }

        var draft = ReadDraft();
        if (_createFile)
        {
            SetStatus(Strings.Get("NewFileOnConnect"), null);
            return;
        }

        using var testing = new CancellationTokenSource();
        _testing = testing;
        SetBusy(true);
        SetStatus(Strings.Get("Testing"), null);
        try
        {
            var prompter = new CredentialDialogs(Root);
            var record = draft.ToConnection();
            var replaced = new HashSet<string>(StringComparer.Ordinal);
            while (true)
            {
                try
                {
                    await _workbench.Core.TestConnectionAsync(record, draft.Secrets(), prompter, testing.Token).ConfigureAwait(true);
                    break;
                }
                catch (TableProException exception) when (exception.Error.HostKey is { TrustAllowed: true } key && replaced.Add(key.Host))
                {
                    if (!await prompter.RecoverHostKeyAsync(
                        _workbench.Core, record, exception.Error.HostKey!, testing.Token).ConfigureAwait(true))
                    {
                        throw;
                    }
                }
            }

            SetStatus(Strings.Get("TestSucceeded"), true);
        }
        catch (TableProException exception)
        {
            SetFailure(exception.Error);
        }
        catch (OperationCanceledException)
        {
            SetStatus(string.Empty, null);
        }
        finally
        {
            _testing = null;
            SetBusy(false);
        }
    }

    private async void OnSave(object sender, RoutedEventArgs e) => await SaveAsync(connect: false).ConfigureAwait(true);

    private async void OnConnect(object sender, RoutedEventArgs e) => await SaveAsync(connect: true).ConfigureAwait(true);

    private async Task SaveAsync(bool connect)
    {
        if (_busy || !Validate())
        {
            return;
        }

        var draft = ReadDraft();
        SetBusy(true);
        try
        {
            if (_createFile && draft.IsFileEngine)
            {
                await CreateFileAsync(draft).ConfigureAwait(true);
            }

            var secrets = draft.Secrets();
            var saved = await _workbench.Library.SaveAsync(draft.ToConnection(), secrets).ConfigureAwait(true);
            _workbench.NotifyLibraryChanged();
            var changesConnect = _existing is null
                || secrets != ConnectionSecrets.None
                || ConnectionDraft.ChangesConnect(_existing, saved);
            Completed?.Invoke(this, new FormResult(saved, connect, changesConnect));
            Close();
        }
        catch (TableProException exception)
        {
            SetFailure(exception.Error);
            SetBusy(false);
        }
    }

    private async Task CreateFileAsync(ConnectionDraft draft)
    {
        var path = draft.Database.Trim();
        if (File.Exists(path))
        {
            _createFile = false;
            return;
        }

        var session = await _workbench.Core.OpenFileAsync(new FileOpenOptions(path, draft.EngineId, Create: true)).ConfigureAwait(true);
        await session.DisposeAsync().ConfigureAwait(true);
        _createFile = false;
        SetStatus(Strings.Format("FileCreated", Path.GetFileName(path)), true);
    }
}
