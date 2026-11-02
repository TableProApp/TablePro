using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.ConnectionForm;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.App.Views;
using TablePro.Interop;
using Windows.Graphics;
using Windows.System;

namespace TablePro.App;

// The one window: the title bar, the menu bar and a NavigationView whose rail holds the Connections page, one item
// per open connection and Settings. The rail stays hidden until a connection opens.
public sealed partial class MainWindow : Window, IShell
{
    private readonly Workbench _workbench;
    private readonly HomeView _home;
    private readonly List<OpenConnection> _open = [];
    private readonly Dictionary<string, ConnectionFormWindow> _forms = [];
    private SettingsView? _settings;
    private OpenConnection? _front;

    internal MainWindow(Workbench workbench)
    {
        _workbench = workbench;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        Title = "TablePro";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop();
        }

        var scale = WindowInterop.Scale(this);
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)(1280 * scale), area.Width);
        var height = Math.Min((int)(820 * scale), area.Height);
        AppWindow.MoveAndResize(new RectInt32(
            area.X + ((area.Width - width) / 2),
            area.Y + ((area.Height - height) / 2),
            width,
            height));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(720 * scale);
            presenter.PreferredMinimumHeight = (int)(480 * scale);
        }

        _home = new HomeView(workbench, this);
        Rail.Content = _home;
        Rail.SelectedItem = HomeItem;
        Themes.Apply(this, workbench.Settings.Theme);
        workbench.SettingsChanged += (_, _) => Themes.Apply(this, workbench.Settings.Theme);
        AppWindow.Closing += OnClosing;
        UpdateRail();
        if (workbench.Settings.ReopenSession)
        {
            Restore(workbench.Sessions.Load());
        }
    }

    public void NewConnection() => ShowForm(null);

    public void EditConnection(SavedConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ShowForm(connection);
    }

    public void Connect(SavedConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        Open(new SessionConnection
        {
            ConnectionId = connection.Id,
            Name = connection.Name,
            EngineId = connection.EngineId,
        });
    }

    public async Task OpenFileAsync()
    {
        var picker = new FileOpenPicker(AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var suffix in _workbench.Engines.SelectMany(engine => engine.FileSuffixes).Distinct())
        {
            picker.FileTypeFilter.Add("." + suffix);
        }

        picker.FileTypeFilter.Add("*");
        var result = await picker.PickSingleFileAsync();
        if (result is not null)
        {
            OpenFile(result.Path);
        }
    }

    public async Task ImportAsync()
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".json");
        var result = await picker.PickSingleFileAsync();
        if (result is null)
        {
            return;
        }

        ShowHome();
        try
        {
            var summary = await _workbench.Library.ImportAsync(result.Path);
            _workbench.NotifyLibraryChanged();
            _home.ShowMessage(Strings.Format("ImportDone", summary.Added, summary.Updated), InfoBarSeverity.Success);
        }
        catch (TableProException exception)
        {
            _home.ShowMessage(Strings.Error(exception.Error), InfoBarSeverity.Error);
        }
    }

    public async Task OpenSampleAsync()
    {
        try
        {
            Connect(await _workbench.InstallSampleAsync());
        }
        catch (Exception exception) when (exception is TableProException or IOException or UnauthorizedAccessException)
        {
            ShowHome();
            _home.ShowMessage(Strings.Error(exception), InfoBarSeverity.Error);
        }
    }

    public void ShowSettings()
    {
        if (Rail.IsPaneVisible)
        {
            Rail.SelectedItem = Rail.SettingsItem;
        }
        else
        {
            Show(Settings());
        }
    }

    internal void OpenFile(string path)
    {
        Open(new SessionConnection { FilePath = path, Name = Path.GetFileName(path) });
    }

    private SettingsView Settings() => _settings ??= new SettingsView(_workbench);

    private void Restore(SessionState state)
    {
        foreach (var connection in state.Connections)
        {
            Add(connection);
        }

        if (state.Front >= 0 && state.Front < _open.Count)
        {
            Select(_open[state.Front]);
        }
    }

    private void Open(SessionConnection origin)
    {
        var open = _open.FirstOrDefault(item => item.Matches(origin.ConnectionId, origin.FilePath)) ?? Add(origin);
        Select(open);
        if (open.State == ConnectionState.Failed)
        {
            _ = open.ConnectAsync();
        }
    }

    private OpenConnection Add(SessionConnection origin)
    {
        var open = new OpenConnection(_workbench, origin);
        open.StateChanged += (_, _) => UpdateCommands();
        open.Cancelled += async (_, _) => await CloseConnectionAsync(open);
        open.View.CommandsChanged += (_, _) => UpdateCommands();
        open.View.EditRequested += async (_, _) => await EditAsync(open);
        _open.Add(open);
        var index = Rail.MenuItems.IndexOf(RailSeparator) + _open.Count;
        Rail.MenuItems.Insert(index, open.RailItem);
        UpdateRail();
        return open;
    }

    private void Select(OpenConnection open)
    {
        if (!ReferenceEquals(Rail.SelectedItem, open.RailItem))
        {
            Rail.SelectedItem = open.RailItem;
        }
        else
        {
            Show(open);
        }
    }

    private void Show(OpenConnection open)
    {
        _front = open;
        Rail.Content = open.View;
        AppTitleBar.Subtitle = open.Name;
        AppTitleBar.IsBackButtonVisible = false;
        if (open.State == ConnectionState.NotConnected)
        {
            _ = open.ConnectAsync();
        }

        UpdateCommands();
    }

    private void Show(UIElement page)
    {
        Rail.Content = page;
        AppTitleBar.Subtitle = string.Empty;
        // While the rail is hidden, Settings is reached from the Connections page, so the title bar leads back.
        AppTitleBar.IsBackButtonVisible = !Rail.IsPaneVisible && ReferenceEquals(page, _settings);
        UpdateCommands();
    }

    private void ShowHome()
    {
        if (Rail.IsPaneVisible)
        {
            Rail.SelectedItem = HomeItem;
        }
        else
        {
            Show(_home);
        }
    }

    private void UpdateRail()
    {
        var visible = _open.Count > 0;
        Rail.IsPaneVisible = visible;
        AppTitleBar.IsPaneToggleButtonVisible = visible;
        _home.SetSettingsButtonVisible(!visible);
        if (!visible && ReferenceEquals(Rail.Content, _settings))
        {
            AppTitleBar.IsBackButtonVisible = true;
        }
    }

    private async Task CloseConnectionAsync(OpenConnection open)
    {
        var wasShown = ReferenceEquals(Rail.Content, open.View);
        await open.DisconnectAsync();
        _open.Remove(open);
        Rail.MenuItems.Remove(open.RailItem);
        if (ReferenceEquals(_front, open))
        {
            _front = null;
        }

        UpdateRail();
        if (wasShown)
        {
            ShowHome();
        }
    }

    private async Task EditAsync(OpenConnection open)
    {
        if (open.ConnectionId is not { } id)
        {
            return;
        }

        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync();
            if (snapshot.Connections.FirstOrDefault(connection => connection.Id == id) is { } saved)
            {
                ShowForm(saved);
            }
        }
        catch (TableProException exception)
        {
            open.View.ShowFailed(Strings.Error(exception.Error), exception.Error.Message);
        }
    }

    private void ShowForm(SavedConnection? existing)
    {
        var key = ConnectionFormWindow.Keys(existing?.Id);
        if (_forms.TryGetValue(key, out var shown))
        {
            shown.Activate();
            return;
        }

        var form = new ConnectionFormWindow(_workbench, this, existing);
        _forms[key] = form;
        form.Closed += (_, _) => _forms.Remove(key);
        form.Completed += async (_, result) => await OnFormCompletedAsync(result);
        form.Activate();
    }

    private async Task OnFormCompletedAsync(FormResult result)
    {
        var open = _open.FirstOrDefault(item => item.Matches(result.Saved.Id, null));
        if (open is not null)
        {
            open.Rename(result.Saved.Name);
        }

        if (!result.Connect)
        {
            return;
        }

        // An edited connection that is open connects again with what was saved.
        if (open is not null && open.State is ConnectionState.Connected or ConnectionState.Failed)
        {
            await open.DisconnectAsync();
        }

        Connect(result.Saved);
    }

    private void OnRailSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            Show(Settings());
        }
        else if (args.SelectedItem is NavigationViewItem { Tag: OpenConnection open })
        {
            Show(open);
        }
        else
        {
            Show(_home);
        }
    }

    private void OnBackRequested(TitleBar sender, object args) => Show(_home);

    private void OnPaneToggleRequested(TitleBar sender, object args) => Rail.IsPaneOpen = !Rail.IsPaneOpen;

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        foreach (var form in _forms.Values.ToList())
        {
            form.Close();
        }

        SaveSession();
    }

    private void SaveSession()
    {
        var connections = _open.Select(open => open.Snapshot()).ToList();
        var front = _front is null ? (connections.Count > 0 ? 0 : -1) : _open.IndexOf(_front);
        try
        {
            _workbench.Sessions.Save(new SessionState { Connections = connections, Front = front });
        }
        catch (IOException)
        {
            // A session that cannot be written only means the next launch starts on the Connections page.
        }
    }

    private WorkspaceView? Workspace => (Rail.Content as WorkspaceView) is { IsConnected: true } view ? view : null;

    private void UpdateCommands()
    {
        var workspace = Workspace;
        var tab = workspace?.ActiveTab;
        var front = Rail.Content is WorkspaceView ? _front : null;
        MenuNewQueryTab.IsEnabled = workspace is not null;
        MenuCloseTab.IsEnabled = tab is not null;
        MenuShowObjects.IsEnabled = workspace is not null;
        MenuShowObjects.IsChecked = workspace?.ObjectsVisible ?? true;
        MenuFilterObjects.IsEnabled = workspace is not null;
        MenuRefresh.IsEnabled = workspace is not null;
        MenuEditConnection.IsEnabled = front?.ConnectionId is not null;
        MenuReconnect.IsEnabled = front is { State: ConnectionState.Connected or ConnectionState.Failed };
        MenuDisconnect.IsEnabled = front is not null;
        MenuRun.IsEnabled = tab is { IsRunning: false };
        MenuStop.IsEnabled = tab is { IsRunning: true };
        var editor = tab?.Editor is not null;
        foreach (var item in new[] { MenuUndo, MenuRedo, MenuCut, MenuPaste, MenuFind })
        {
            item.IsEnabled = editor;
        }

        MenuCopy.IsEnabled = tab is not null;
        MenuSelectAll.IsEnabled = tab is not null;
    }

    private void OnNewConnection(object sender, RoutedEventArgs e) => NewConnection();

    private async void OnOpenFile(object sender, RoutedEventArgs e) => await OpenFileAsync();

    private async void OnImport(object sender, RoutedEventArgs e) => await ImportAsync();

    private void OnNewQueryTab(object sender, RoutedEventArgs e) => Workspace?.NewQueryTab();

    private void OnCloseTab(object sender, RoutedEventArgs e) => Workspace?.CloseActiveTab();

    private void OnShowSettings(object sender, RoutedEventArgs e) => ShowSettings();

    private void OnExit(object sender, RoutedEventArgs e) => Close();

    private void OnUndo(object sender, RoutedEventArgs e) => EditorKey(VirtualKey.Z);

    private void OnRedo(object sender, RoutedEventArgs e) => EditorKey(VirtualKey.Y);

    private void OnCut(object sender, RoutedEventArgs e) => Workspace?.ActiveTab?.Editor?.Cut();

    private async void OnCopy(object sender, RoutedEventArgs e)
    {
        switch (Workspace?.ActiveTab)
        {
            case { GridIsTarget: true } tab:
                await tab.Grid.CopySelectionAsync();
                break;
            case { Editor: { } editor }:
                editor.Copy();
                break;
            default:
                break;
        }
    }

    private async void OnPaste(object sender, RoutedEventArgs e)
    {
        if (Workspace?.ActiveTab?.Editor is { } editor)
        {
            await editor.PasteAsync();
        }
    }

    private void OnSelectAll(object sender, RoutedEventArgs e)
    {
        if (Workspace?.ActiveTab is { GridIsTarget: true } tab)
        {
            tab.Grid.SelectAll();
            tab.Grid.Focus(FocusState.Programmatic);
            return;
        }

        EditorKey(VirtualKey.A);
    }

    private void OnFind(object sender, RoutedEventArgs e) => EditorKey(VirtualKey.F);

    // The menu sends the editor the key it already answers, so a menu command and its shortcut cannot differ.
    private void EditorKey(VirtualKey key)
    {
        if (Workspace?.ActiveTab?.Editor is { } editor)
        {
            editor.HandleKey(key, control: true, shift: false, alt: false);
            editor.Focus(FocusState.Programmatic);
        }
    }

    private void OnShowConnections(object sender, RoutedEventArgs e)
    {
        ShowHome();
        _home.FocusSearch();
    }

    private void OnToggleObjects(object sender, RoutedEventArgs e)
    {
        Workspace?.ToggleObjects();
        UpdateCommands();
    }

    private void OnFilterObjects(object sender, RoutedEventArgs e) => Workspace?.FocusFilter();

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        if (Workspace is { } workspace)
        {
            await workspace.RefreshAsync();
        }
    }

    private async void OnEditConnection(object sender, RoutedEventArgs e)
    {
        if (_front is not null)
        {
            await EditAsync(_front);
        }
    }

    private async void OnReconnect(object sender, RoutedEventArgs e)
    {
        if (_front is { } open)
        {
            await open.DisconnectAsync();
            await open.ConnectAsync();
        }
    }

    private async void OnDisconnect(object sender, RoutedEventArgs e)
    {
        if (_front is { } open)
        {
            await CloseConnectionAsync(open);
        }
    }

    private void OnRun(object sender, RoutedEventArgs e) => Workspace?.ActiveTab?.Run();

    private void OnStop(object sender, RoutedEventArgs e) => Workspace?.ActiveTab?.Stop();

    private async void OnDocumentation(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(SettingsView.DocumentationUri);

    private async void OnReportIssue(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(SettingsView.IssuesUri);

    private async void OnOpenSample(object sender, RoutedEventArgs e) => await OpenSampleAsync();

    private void OnAbout(object sender, RoutedEventArgs e)
    {
        ShowSettings();
        Settings().ShowAbout();
    }
}
