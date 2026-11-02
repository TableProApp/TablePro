using System.Globalization;
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

internal sealed record FormResult(SavedConnection Saved, bool Connect);

// The connection form: its own window, owned by the main one and not modal, so a dialog elsewhere in the app can
// still open (only one ContentDialog opens per thread). Page one picks the engine, page two holds every field.
public sealed partial class ConnectionFormWindow : Window
{
    private static readonly string[] Colors = ["", "blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate"];

    private readonly Workbench _workbench;
    private readonly bool _isNew;
    private ConnectionDraft? _draft;
    private DatabaseEngine? _engine;
    private bool _createFile;
    private IReadOnlyList<ConnectionGroup> _groups = [];
    private Guid? _groupToSelect;
    private CancellationTokenSource? _testing;
    private bool _busy;

    internal ConnectionFormWindow(Workbench workbench, Window owner, SavedConnection? existing)
    {
        _workbench = workbench;
        _isNew = existing is null;
        Key = Keys(existing?.Id);
        InitializeComponent();
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
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMinimizable = false;
            presenter.PreferredMinimumWidth = (int)(560 * scale);
            presenter.PreferredMinimumHeight = (int)(480 * scale);
        }
    }

    private void FillEngines(string query)
    {
        var groups = _workbench.Engines
            .Where(engine => engine.DisplayName.Contains(query.Trim(), StringComparison.CurrentCultureIgnoreCase))
            .GroupBy(EngineCategory)
            .OrderBy(group => group.Key)
            .Select(group => new EngineGroup(
                Strings.Get("EngineGroup_" + group.Key),
                [.. group.OrderBy(engine => engine.DisplayName, StringComparer.CurrentCulture).Select(Choice)]))
            .ToList();
        EngineSource.Source = groups;
    }

    private static EngineChoice Choice(DatabaseEngine engine) => new(
        engine,
        engine.DefaultPort is { } port
            ? Strings.Format("EngineDefaultPort", port)
            : string.Join(", ", engine.FileSuffixes.Select(suffix => "." + suffix)));

    // Network engines by data model, then the engines that open a file.
    private static int EngineCategory(DatabaseEngine engine) => engine switch
    {
        { DefaultPort: null } => 3,
        { DataModel: DataModel.Document } => 1,
        { DataModel: DataModel.KeyValue } => 2,
        _ => 0,
    };

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
        EngineIcon.Symbol = engine.DefaultPort is null ? Symbol.Document : Symbol.Library;
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
        TlsModeBox.SelectedIndex = (int)draft.TlsMode;
        CaFileBox.Text = draft.CaFile;
        ClientCertificateBox.Text = draft.ClientCertificate;
        ClientKeyBox.Text = draft.ClientKey;
        SafeModeBox.SelectedIndex = (int)draft.SafeMode;
        TimeoutBox.Text = draft.Timeout;
        ColorBox.SelectedIndex = Math.Max(0, Array.IndexOf(Colors, draft.Color ?? string.Empty));
        NameBox.PlaceholderText = draft.SuggestedName();
        ClearErrors();
        SetStatus(string.Empty, null);
        UpdateSsh();
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
            draft.Password = PasswordInput.Password;
            draft.Database = DatabaseBox.Text;
            draft.UseSsh = SshSwitch.IsOn;
            draft.SshHost = SshHostBox.Text;
            draft.SshPort = SshPortBox.Text;
            draft.SshUserName = SshUserBox.Text;
            draft.SshAuth = (SshAuthMethod)Math.Max(0, SshAuthBox.SelectedIndex);
            draft.SshKeyPath = SshKeyBox.Text;
            draft.SshPassword = SshPasswordInput.Password;
            draft.TlsMode = (TlsMode)Math.Max(0, TlsModeBox.SelectedIndex);
            draft.CaFile = CaFileBox.Text;
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

    private Control Field(FormField field) => field switch
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
    private static void SetError(Control field, string message)
    {
        var text = new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"],
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
        StatusText.Text = text;
        StatusText.Foreground = success switch
        {
            true => (Brush)Application.Current.Resources["SystemFillColorSuccessBrush"],
            false => (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"],
            null => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
        ToolTipService.SetToolTip(StatusText, string.IsNullOrEmpty(text) ? null : text);
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        TestButton.IsEnabled = !busy;
        ConnectButton.IsEnabled = !busy;
        SaveButton.IsEnabled = !busy;
        TestRing.IsActive = busy;
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
        OptionsExpander.Description = string.IsNullOrWhiteSpace(TimeoutBox.Text)
            ? Strings.Format("OptionsSummary", safeMode)
            : Strings.Format("OptionsSummaryTimeout", safeMode, TimeoutBox.Text.Trim());
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
        UpdateSummaries();
        if (SshSwitch.IsOn)
        {
            SshExpander.IsExpanded = true;
        }
    }

    private void OnSshAuthChanged(object sender, SelectionChangedEventArgs e) => UpdateSsh();

    private void OnEngineSearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args) =>
        FillEngines(sender.Text);

    // A GridView item's name comes from its container, not from the template inside it.
    private void OnEngineContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
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
            picker.FileTypeChoices.Add(_engine!.DisplayName, [.. suffixes.Select(suffix => "." + suffix)]);
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
            await _workbench.Core.TestConnectionAsync(draft.ToConnection(), draft.Secrets(), testing.Token).ConfigureAwait(true);
            SetStatus(Strings.Get("TestSucceeded"), true);
        }
        catch (TableProException exception)
        {
            SetStatus(Strings.Error(exception.Error), false);
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

            var saved = await _workbench.Library.SaveAsync(draft.ToConnection(), draft.Secrets()).ConfigureAwait(true);
            _workbench.NotifyLibraryChanged();
            Completed?.Invoke(this, new FormResult(saved, connect));
            Close();
        }
        catch (TableProException exception)
        {
            SetStatus(Strings.Error(exception.Error), false);
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
        SetStatus(string.Format(CultureInfo.CurrentCulture, Strings.Get("FileCreated"), Path.GetFileName(path)), true);
    }
}
