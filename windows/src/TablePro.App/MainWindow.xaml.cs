using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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

// The primary window holds the rail; a tab window holds one connection's tabs moved out of it, and hands the
// shell's own commands (the Connections page, Settings, the connection form) back to the primary.
public sealed partial class MainWindow : Window, IShell, IWorkspaceHost
{
    // A change is on disk this long after it, however fast the typing goes on.
    private static readonly TimeSpan SaveDelay = TimeSpan.FromSeconds(2);

    // A session file another program holds is tried again, each time later, until this far apart.
    private static readonly TimeSpan LongestRetry = TimeSpan.FromSeconds(30);

    // A server that does not answer holds the exit only this long; the process ends what is left.
    private static readonly TimeSpan CloseLimit = TimeSpan.FromSeconds(5);

    private readonly Workbench _workbench;
    private readonly MainWindow _primary;
    private readonly HomeView? _home;
    private readonly List<OpenConnection> _open = [];
    private readonly Dictionary<string, ConnectionFormWindow> _forms = [];
    private readonly List<MainWindow> _tabWindows = [];
    // Native AOT trims OverlappedPresenter's wrapper, so AppWindow.Presenter reads back as its base type.
    private readonly OverlappedPresenter _presenter = OverlappedPresenter.Create();
    private readonly bool _restoreMaximized;
    private readonly IReadOnlyList<TabWindowState> _restoreWindows = [];

    // The primary's alone: it writes the session for every window.
    private readonly SessionWriter? _saves;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer? _saveTimer;
    private readonly SessionEnd? _sessionEnd;
    private TimeSpan _nextRetry = SaveDelay;
    private SettingsView? _settings;
    private OpenConnection? _front;

    // A tab window that has not taken a tab yet, kept hidden for the next drag out of a strip.
    private MainWindow? _spare;
    private bool _isSpare;
    private bool _closing;
    private bool _checkingClose;

    internal MainWindow(Workbench workbench)
    {
        _workbench = workbench;
        _primary = this;
        InitializeComponent();
        Prepare();
        Title = "TablePro";
        _saves = new SessionWriter(workbench.Sessions);
        _saveTimer = DispatcherQueue.CreateTimer();
        _saveTimer.Interval = SaveDelay;
        _saveTimer.IsRepeating = false;
        _saveTimer.Tick += async (timer, _) =>
        {
            timer.Stop();
            timer.Interval = SaveDelay;
            await SaveSessionInBackgroundAsync();
        };
        var sessionEnd = new SessionEnd(this, OnSessionEnding, ShutdownBlockReason, OnSessionHeld);
        _sessionEnd = sessionEnd;
        Closed += (_, _) => sessionEnd.Dispose();

        // Where the window stood last time, whether or not its connections come back.
        var session = workbench.Sessions.Load();
        if (session.Window is { } placement && WindowInterop.Restore(this, placement))
        {
            _restoreMaximized = placement.Maximized;
        }

        workbench.ObjectPaneWidth = session.ObjectPaneWidth ?? ObjectPane.DefaultWidth;
        _home = new HomeView(workbench, this);
        Rail.Content = _home;
        Rail.SelectedItem = HomeItem;
        Closed += (_, _) => _home.WindowClosed();
        UpdateRail();
        if (workbench.Settings.ReopenSession)
        {
            Restore(session);
            _restoreWindows = session.TabWindows;
            _ = RefreshMarksAsync();
        }
    }

    private MainWindow(
        Workbench workbench, MainWindow primary, OpenConnection connection, WindowPlacement? placement, bool spare)
    {
        _workbench = workbench;
        _primary = primary;
        _isSpare = spare;
        InitializeComponent();
        Prepare();
        if (placement is not null && WindowInterop.Restore(this, placement))
        {
            _restoreMaximized = placement.Maximized;
        }

        // Shown and hidden again by TabView on every press on a tab (microsoft/microsoft-ui-xaml#10154, #10155).
        if (spare)
        {
            AppWindow.IsShownInSwitchers = false;
            WindowInterop.Cloak(this, true);
        }

        AppTitleBar.IsPaneToggleButtonVisible = false;
        Add(connection);
        Show(connection);
    }

    // Raised once the last session is written, before the connections close, so a new launch may own the data folder.
    internal event EventHandler? SessionSaved;

    public bool IsPrimary => ReferenceEquals(_primary, this);

    public bool CanMoveTabs => !_primary._checkingClose && !_closing;

    public bool AcceptsTabs => !_isSpare && !_primary._checkingClose && AppWindow.IsVisible;

    private WorkspaceView? Workspace => (Rail.Content as WorkspaceView) is { IsConnected: true } view ? view : null;

    private IEnumerable<MainWindow> AllWindows =>
        _spare is null ? [this, .. _tabWindows] : [this, .. _tabWindows, _spare];

    // A maximized window is maximized once shown, over the bounds it restores to.
    public void ActivateRestored()
    {
        Activate();
        if (_restoreMaximized)
        {
            _presenter.Maximize();
        }

        foreach (var saved in _restoreWindows)
        {
            OpenTabWindow(new OpenConnection(_workbench, saved.Connection), saved.Placement).ActivateRestored();
        }
    }

    public void NewConnection()
    {
        if (!IsPrimary)
        {
            _primary.NewConnection();
            return;
        }

        ShowForm(null);
    }

    public void EditConnection(SavedConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ShowForm(connection);
    }

    public void Connect(SavedConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (!IsPrimary)
        {
            _primary.Activate();
            _primary.Connect(connection);
            return;
        }

        var open = Open(new SessionConnection
        {
            ConnectionId = connection.Id,
            Name = connection.Name,
            EngineId = connection.EngineId,
        });
        open.Mark(connection.EngineId, connection.Color);
    }

    public async Task OpenFileAsync()
    {
        if (!IsPrimary)
        {
            await _primary.OpenFileAsync();
            return;
        }

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
        if (_home is null)
        {
            _primary.Activate();
            await _primary.ImportAsync();
            return;
        }

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
        if (_home is null)
        {
            _primary.Activate();
            await _primary.OpenSampleAsync();
            return;
        }

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
        if (!IsPrimary)
        {
            _primary.Activate();
            _primary.ShowSettings();
            return;
        }

        if (Rail.IsPaneVisible)
        {
            Rail.SelectedItem = Rail.SettingsItem;
        }
        else
        {
            Show(Settings());
        }
    }

    WindowId IWorkspaceHost.TearOutWindow(OpenConnection connection) => _primary.SpareFor(connection);

    void IWorkspaceHost.TearOut(TabViewItem tab, WindowId window) => _primary.Receive(tab, window);

    void IWorkspaceHost.MoveToNewWindow(TabViewItem tab) => _primary.MoveOut(tab);

    internal void OpenFile(string path)
    {
        Open(new SessionConnection { FilePath = path, Name = Path.GetFileName(path) });
    }

    // Each press on a tab asks for a window before any drag, so one is kept hidden for the same connection.
    private WindowId SpareFor(OpenConnection connection)
    {
        if (_spare is { } spare && spare._front?.Session == connection.Session)
        {
            return spare.AppWindow.Id;
        }

        DropSpare();
        _spare = new MainWindow(_workbench, this, connection.Adopt(), placement: null, spare: true);
        return _spare.AppWindow.Id;
    }

    private void Receive(TabViewItem tab, WindowId window)
    {
        var target = AllWindows.FirstOrDefault(each => each.AppWindow.Id.Value == window.Value);
        if (target?.Workspace is not { } workspace)
        {
            return;
        }

        var promoted = ReferenceEquals(target, _spare);
        if (promoted)
        {
            _spare = null;
            target.Promote();
            _tabWindows.Add(target);
        }

        WorkspaceView.HolderOf(tab)?.Release(tab);
        workspace.Take(tab);
        if (promoted)
        {
            workspace.Start();
        }
    }

    private void MoveOut(TabViewItem tab)
    {
        if (!CanMoveTabs)
        {
            return;
        }

        var source = WorkspaceView.HolderOf(tab);
        var from = AllWindows.FirstOrDefault(window => window._open.Any(open => open.View == source));
        if (source is null || from?._open.First(open => open.View == source) is not { } connection)
        {
            return;
        }

        // Cascaded from the window the tab leaves, at the size that window has when restored.
        var placement = WindowInterop.Placement(from) is { } bounds
            ? bounds with
            {
                X = bounds.X + (int)(32 * WindowInterop.Scale(from)),
                Y = bounds.Y + (int)(32 * WindowInterop.Scale(from)),
                Maximized = false,
            }
            : null;
        var window = OpenTabWindow(connection.Adopt(), placement);
        source.Release(tab);
        window.Workspace?.Take(tab);
        window.Workspace?.Start();
        window.Activate();
    }

    private void Prepare()
    {
        var scale = WindowInterop.Scale(this);
        _presenter.PreferredMinimumWidth = (int)(720 * scale);
        _presenter.PreferredMinimumHeight = (int)(480 * scale);
        AppWindow.SetPresenter(_presenter);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        var tabContextMenu = new WindowContextMenu(this, point => Workspace?.ShowTabContextMenu(point) == true);
        Closed += (_, _) => tabContextMenu.Dispose();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop();
        }

        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)(1280 * scale), area.Width);
        var height = Math.Min((int)(820 * scale), area.Height);
        AppWindow.MoveAndResize(new RectInt32(
            area.X + ((area.Width - width) / 2),
            area.Y + ((area.Height - height) / 2),
            width,
            height));
        Themes.Apply(this, _workbench.Settings.Theme);
        _workbench.SettingsChanged += OnSettingsChanged;
        _workbench.LibraryChanged += OnLibraryChanged;
        AppWindow.Closing += OnClosing;
        Closed += OnClosed;
    }

    private MainWindow OpenTabWindow(OpenConnection connection, WindowPlacement? placement)
    {
        var window = new MainWindow(_workbench, this, connection, placement, spare: false);
        _tabWindows.Add(window);
        return window;
    }

    // The spare took a tab: it now shows as a window of its own.
    private void Promote()
    {
        _isSpare = false;
        WindowInterop.Cloak(this, false);
        AppWindow.IsShownInSwitchers = true;
        if (_front is { } open)
        {
            ShowName(open);
        }
    }

    private void DropSpare()
    {
        if (_spare is { } spare)
        {
            _spare = null;
            spare.CloseForGood();
        }
    }

    private void CloseForGood()
    {
        _closing = true;
        Close();
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

    private OpenConnection Open(SessionConnection origin)
    {
        var open = _open.FirstOrDefault(item => item.Matches(origin.ConnectionId, origin.FilePath)) ?? Add(origin);
        Select(open);
        if (open.State == ConnectionState.Failed)
        {
            _ = open.ConnectAsync();
        }

        return open;
    }

    private async void OnLibraryChanged(object? sender, EventArgs e) => await RefreshMarksAsync();

    private void OnSettingsChanged(object? sender, EventArgs e) => Themes.Apply(this, _workbench.Settings.Theme);

    private async Task RefreshMarksAsync()
    {
        if (!_open.Any(open => open.ConnectionId is not null))
        {
            return;
        }

        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync();
            foreach (var open in _open)
            {
                if (snapshot.Connections.FirstOrDefault(saved => saved.Id == open.ConnectionId) is { } saved)
                {
                    open.Mark(saved.EngineId, saved.Color);
                    if (saved.Name != open.Name)
                    {
                        open.Rename(saved.Name);
                        SessionChanged();
                        if (ReferenceEquals(_front, open))
                        {
                            ShowName(open);
                        }
                    }
                }
            }
        }
        catch (TableProException)
        {
            // The marks stay as they were; the Connections page says what the library could not read.
        }
    }

    private OpenConnection Add(SessionConnection origin) => Add(new OpenConnection(_workbench, origin));

    private OpenConnection Add(OpenConnection open)
    {
        open.StateChanged += (_, _) => UpdateCommands();
        open.Cancelled += async (_, _) => await CloseConnectionAsync(open);
        open.View.CommandsChanged += (_, _) => UpdateCommands();
        open.View.SessionChanged += (_, _) => SessionChanged();
        open.View.EditRequested += async (_, _) => await EditAsync(open);
        open.View.Host = this;
        _open.Add(open);
        SessionChanged();
        if (IsPrimary)
        {
            var index = Rail.MenuItems.IndexOf(RailSeparator) + _open.Count;
            Rail.MenuItems.Insert(index, open.RailItem);
            UpdateRail();
        }
        else
        {
            open.View.Emptied += (_, _) => Close();
        }

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
        open.View.ApplyPaneWidth();
        SetContent(open.View);
        ShowName(open);
        AppTitleBar.IsBackButtonVisible = false;
        if (open.State == ConnectionState.NotConnected)
        {
            _ = open.ConnectAsync();
        }

        UpdateCommands();
        SessionChanged();
    }

    private void Show(UIElement page)
    {
        SetContent(page);
        AppTitleBar.Subtitle = string.Empty;
        // While the rail is hidden, Settings is reached from the Connections page, so the title bar leads back.
        AppTitleBar.IsBackButtonVisible = !Rail.IsPaneVisible && ReferenceEquals(page, _settings);
        UpdateCommands();
    }

    private void SetContent(UIElement page)
    {
        if (Rail.Content is WorkspaceView shown && !ReferenceEquals(shown, page))
        {
            shown.Leave();
        }

        Rail.Content = page;
    }

    // A tab window is named for its connection in the taskbar and in Alt+Tab, once it shows.
    private void ShowName(OpenConnection open)
    {
        AppTitleBar.Subtitle = IsPrimary || _isSpare ? open.Name : string.Empty;
        if (!IsPrimary && !_isSpare)
        {
            AppTitleBar.Title = Strings.Format("TabWindowTitle", open.Name);
        }
    }

    private void ShowHome()
    {
        if (_home is null)
        {
            _primary.Activate();
            _primary.ShowHome();
            return;
        }

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
        if (_home is null)
        {
            return;
        }

        var visible = _open.Count > 0;
        Rail.IsPaneVisible = visible;
        AppTitleBar.IsPaneToggleButtonVisible = visible;
        _home.SetSettingsButtonVisible(!visible);
        if (!visible && ReferenceEquals(Rail.Content, _settings))
        {
            AppTitleBar.IsBackButtonVisible = true;
        }
    }

    // Disconnect asks about held transactions in either window, and about a running query in neither, as Reconnect.
    private async Task CloseConnectionAsync(OpenConnection open)
    {
        if (!IsPrimary)
        {
            await RequestCloseAsync(askAboutRunning: false);
            return;
        }

        if (!await ConfirmDisconnectAsync(open))
        {
            return;
        }

        DropSpare();
        var wasShown = ReferenceEquals(Rail.Content, open.View);
        if (wasShown)
        {
            open.View.Leave();
        }

        await open.DisconnectAsync();
        _open.Remove(open);
        Rail.MenuItems.Remove(open.RailItem);
        if (ReferenceEquals(_front, open))
        {
            _front = null;
        }

        SessionChanged();
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
        if (!IsPrimary)
        {
            _primary.ShowForm(existing);
            return;
        }

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

        // An edited connection that is open connects again with what was saved, and keeps its tabs.
        var reconnecting = result.Connect && open is { State: ConnectionState.Connected or ConnectionState.Failed }
            ? open
            : null;
        if (result.ChangesConnect)
        {
            RestartConnects(result.Saved);
        }

        // The core gave the open sessions the saved rules before the save returned, so the rows on screen follow now.
        await RemaskOpenAsync(result.Saved);
        await ApplySafeModeAsync(result.Saved, reconnecting);
        if (!result.Connect)
        {
            return;
        }

        if (reconnecting is not null)
        {
            if (!await ConfirmDisconnectAsync(reconnecting, offerSave: result.Saved.SafeMode != SafeMode.ReadOnly))
            {
                ShowChangesOnConnect(reconnecting, result.Saved);
                return;
            }

            DropSpare();
            await reconnecting.DisconnectAsync(keepTabs: true);
        }

        Connect(result.Saved);
    }

    private async Task RemaskOpenAsync(SavedConnection saved)
    {
        List<MainWindow> windows = [this, .. _tabWindows];
        foreach (var each in windows.SelectMany(window => window._open).Where(item => item.Matches(saved.Id, null)).ToList())
        {
            await each.View.RemaskAsync();
        }
    }

    // The core read the saved connection as each connect under way began, in every window.
    private void RestartConnects(SavedConnection saved)
    {
        List<MainWindow> windows = [this, .. _tabWindows];
        var matching = windows.SelectMany(window => window._open).Where(item => item.Matches(saved.Id, null));
        foreach (var each in matching.ToList())
        {
            _ = each.RestartConnectAsync();
        }
    }

    // A saved level reaches every window's open sessions of the connection at once, as on Linux. Read only is set
    // as a connection opens, so a change across it reconnects once held transactions may go, or waits for the next
    // connect.
    private async Task ApplySafeModeAsync(SavedConnection saved, OpenConnection? reconnecting)
    {
        var crossed = new List<(MainWindow Window, OpenConnection Open)>();
        List<MainWindow> windows = [this, .. _tabWindows];
        foreach (var window in windows)
        {
            foreach (var each in window._open.Where(item => item.Matches(saved.Id, null)))
            {
                if (each.Session is not { } session)
                {
                    continue;
                }

                if (session.SetSafeMode(saved.SafeMode))
                {
                    each.View.HideChangesOnConnect();
                    continue;
                }

                // Until a new connection opens read only, every write on this one is asked about.
                if (saved.SafeMode == SafeMode.ReadOnly)
                {
                    _ = session.SetSafeMode(SafeMode.ConfirmWrites);
                }

                if (!ReferenceEquals(each, reconnecting))
                {
                    crossed.Add((window, each));
                }
            }
        }

        foreach (var (window, each) in crossed)
        {
            if (each.State != ConnectionState.Connected)
            {
                continue;
            }

            // Pending edits are not written on a connection the user is making read only.
            if (await window.ConfirmDisconnectAsync(each, offerSave: saved.SafeMode != SafeMode.ReadOnly))
            {
                DropSpare();
                await each.DisconnectAsync(keepTabs: true);
                await each.ConnectAsync();
            }
            else
            {
                ShowChangesOnConnect(each, saved);
            }
        }
    }

    private static void ShowChangesOnConnect(OpenConnection open, SavedConnection saved) =>
        open.View.ShowChangesOnConnect(saved.SafeMode == SafeMode.ReadOnly && open.Session is { IsReadOnly: false });

    // Disconnecting ends each tab's own connection and its pending edits, so both are asked about first, as closing a
    // tab asks. The connection shows first, since the question names one of its tabs.
    private async Task<bool> ConfirmDisconnectAsync(OpenConnection open, bool offerSave = true)
    {
        var confirmed = new HashSet<IWorkspaceTab>();
        if (!open.View.HasUnconfirmed(confirmed))
        {
            return true;
        }

        Activate();
        if (IsPrimary)
        {
            Select(open);
        }
        else
        {
            Show(open);
        }

        return await open.View.ConfirmCloseAsync(confirmed, offerSave);
    }

    private void OnRailSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_home is null)
        {
            return;
        }

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

    private void OnBackRequested(TitleBar sender, object args)
    {
        if (_home is not null)
        {
            Show(_home);
        }
    }

    private void OnPaneToggleRequested(TitleBar sender, object args) => Rail.IsPaneOpen = !Rail.IsPaneOpen;

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closing)
        {
            return;
        }

        args.Cancel = true;
        if (!_isSpare)
        {
            DispatcherQueue.TryEnqueue(async () => await RequestCloseAsync());
        }
    }

    private async Task RequestCloseAsync(bool askAboutRunning = true)
    {
        if (_primary._checkingClose || _closing)
        {
            return;
        }

        var windows = IsPrimary ? AllWindows.ToList() : [this];
        if (windows.Any(window => WindowDialogs.IsOpen(window.Content.XamlRoot)))
        {
            return;
        }

        _primary._checkingClose = true;
        RefreshTabTransfers();
        try
        {
            var confirmed = new HashSet<IWorkspaceTab>();
            // Apart from confirmed, so a run that ends during the question and leaves a transaction open is asked about.
            var stopped = new HashSet<IWorkspaceTab>();
            while (true)
            {
                if (!await ConfirmTabsAsync(windows, confirmed))
                {
                    return;
                }

                // A tab whose transaction was confirmed is not asked again: that question says its work goes with it.
                var running = askAboutRunning ? RunningQueries(windows, confirmed, stopped) : [];
                if (running.Count == 0)
                {
                    break;
                }

                if (!await ConfirmStopRunningAsync(running))
                {
                    return;
                }

                stopped.UnionWith(running.Select(each => each.Tab));
            }

            if (IsPrimary)
            {
                await ShutDownAsync();
            }
            else
            {
                HandTabsToPrimary();
            }

            CloseForGood();
        }
        finally
        {
            _primary._checkingClose = false;
            RefreshTabTransfers();
        }
    }

    // Held transactions and unsaved changes, tab by tab in every window; a save chosen there runs before the close.
    private static async Task<bool> ConfirmTabsAsync(List<MainWindow> windows, HashSet<IWorkspaceTab> confirmed)
    {
        while (windows.SelectMany(window => window._open).Any(open => open.View.HasUnconfirmed(confirmed)))
        {
            foreach (var window in windows)
            {
                foreach (var open in window._open.Where(open => open.View.HasUnconfirmed(confirmed)).ToList())
                {
                    window.Activate();
                    if (window.IsPrimary)
                    {
                        window.Select(open);
                    }
                    else
                    {
                        window.Show(open);
                    }

                    if (!await open.View.ConfirmCloseAsync(confirmed))
                    {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    private static List<(string Connection, IWorkspaceTab Tab)> RunningQueries(
        List<MainWindow> windows, HashSet<IWorkspaceTab> confirmed, HashSet<IWorkspaceTab> stopped) =>
        [.. windows.SelectMany(window => window._open)
            .SelectMany(open => open.View.RunningQueries()
                .Where(tab => !confirmed.Contains(tab) && !stopped.Contains(tab))
                .Select(tab => (Connection: open.Name, Tab: tab)))];

    // One question for every query still running, as the macOS app asks before it quits; Cancel keeps every window.
    private async Task<bool> ConfirmStopRunningAsync(List<(string Connection, IWorkspaceTab Tab)> running)
    {
        Activate();
        var one = running.Count == 1;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = Strings.Get(one ? "CloseRunningRollsBackOne" : "CloseRunningRollsBackMany"),
            TextWrapping = TextWrapping.Wrap,
        });
        var tabs = new TextBlock
        {
            Text = string.Join("\n", running.Select(each => Strings.Format("CloseRunningTab", each.Tab.Title, each.Connection))),
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetAutomationId(tabs, "CloseRunningTabs");
        content.Children.Add(tabs);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = one ? Strings.Get("CloseRunningTitleOne") : Strings.Format("CloseRunningTitleMany", running.Count),
            Content = content,
            PrimaryButtonText = Strings.Get("CloseRunningButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, Root) == ContentDialogResult.Primary;
    }

    // A tab window's tabs close with it, so the primary reopens them as it reopens a tab closed there.
    private void HandTabsToPrimary()
    {
        foreach (var open in _open)
        {
            var tabs = open.Snapshot().Tabs;
            if (tabs.Count > 0
                && _primary._open.FirstOrDefault(each => each.Matches(open.ConnectionId, open.Origin.FilePath)) is { } home)
            {
                home.View.KeepClosed(tabs);
            }
        }
    }

    private void RefreshTabTransfers()
    {
        foreach (var window in _primary.AllWindows.Where(window => !window._closing))
        {
            foreach (var open in window._open)
            {
                open.View.UpdateTearOut();
            }

            window.UpdateCommands();
        }
    }

    // Window.Close raises no AppWindow.Closing, so Exit runs this itself before it closes the primary.
    private async Task ShutDownAsync()
    {
        if (_closing)
        {
            return;
        }

        _closing = true;
        _saveTimer?.Stop();
        foreach (var form in _forms.Values.ToList())
        {
            form.Close();
        }

        // Before any tab closes, since a closed tab is no longer in what the session lists.
        _ = _saves?.Save(SessionSnapshot(), last: true);
        _workbench.SaveUnsavedSettings();
        SessionSaved?.Invoke(this, EventArgs.Empty);
        DropSpare();
        var windows = AllWindows.ToList();
        foreach (var window in windows)
        {
            window.AppWindow.Hide();
        }

        await CloseConnectionsAsync(windows);
        foreach (var window in _tabWindows.ToList())
        {
            window.CloseForGood();
        }
    }

    // Each tab stops its run and closes its own connection, so a server ends them as a disconnect, not a dropped link.
    private static async Task CloseConnectionsAsync(List<MainWindow> windows)
    {
        var closing = windows.SelectMany(window => window._open).Select(open => open.DisconnectAsync()).ToList();
        try
        {
            await Task.WhenAll(closing).WaitAsync(CloseLimit).ConfigureAwait(true);
        }
        catch (TimeoutException)
        {
            // The process ends the connections still closing.
        }
        catch (TableProException)
        {
            // A connection that could not close cleanly ends with the process.
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _workbench.SettingsChanged -= OnSettingsChanged;
        _workbench.LibraryChanged -= OnLibraryChanged;
        if (IsPrimary)
        {
            return;
        }

        _primary._tabWindows.Remove(this);
        if (ReferenceEquals(_primary._spare, this))
        {
            _primary._spare = null;
        }
        else if (_primary._spare is { _front.Session: { } held }
            && _open.Any(open => ReferenceEquals(open.Session, held)))
        {
            // The hidden spare adopted this window's session on a press on one of its tabs, and would keep it open.
            _primary.DropSpare();
        }

        _primary.SessionChanged();
        _primary._sessionEnd?.Update();
        foreach (var open in _open)
        {
            _ = open.DisconnectAsync();
        }
    }

    // A crash, a kill or a lost power then keeps what the tabs held a moment ago, not what the last exit saved.
    private void SessionChanged()
    {
        if (!IsPrimary)
        {
            _primary.SessionChanged();
            return;
        }

        // Started by the first change and not again until it fires, so steady typing still saves every SaveDelay.
        if (!_closing && _saveTimer is { IsRunning: false } timer)
        {
            timer.Start();
        }
    }

    private async Task SaveSessionInBackgroundAsync()
    {
        if (_closing || _saves is null || _saveTimer is null)
        {
            return;
        }

        var saved = await _saves.SaveInBackgroundAsync(SessionSnapshot());
        if (saved == SessionSave.Written)
        {
            _nextRetry = SaveDelay;
            if (!_saveTimer.IsRunning)
            {
                _saveTimer.Interval = SaveDelay;
            }
        }
        else if (saved == SessionSave.Refused && !_closing && !_saveTimer.IsRunning)
        {
            // Without a next change, the text the file refused would live only in memory until the exit.
            _saveTimer.Interval = _nextRetry;
            _nextRetry = TimeSpan.FromTicks(Math.Min(_nextRetry.Ticks * 2, LongestRetry.Ticks));
            _saveTimer.Start();
        }
    }

    // The app ends after an exception nothing caught, so what the tabs hold is written first.
    internal void SaveSessionBeforeCrash()
    {
        if (_closing || _saves is null)
        {
            return;
        }

        try
        {
            _saveTimer?.Stop();
            _ = _saves.Save(SessionSnapshot(), last: true);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
        }
    }

    // Windows may end the process once this returns, and closes no window first.
    private void OnSessionEnding()
    {
        if (_closing || _saves is null)
        {
            return;
        }

        _saveTimer?.Stop();
        _ = _saves.Save(SessionSnapshot(), last: true);
        _workbench.SaveUnsavedSettings();
        // Restart Manager asks the app to end itself; at a sign-out the process may be gone before this runs.
        DispatcherQueue.TryEnqueue(async () =>
        {
            await ShutDownAsync();
            CloseForGood();
        });
    }

    // A forced Restart Manager close ends the app with no WM_ENDSESSION after a FALSE, so the session is written first.
    private void OnSessionHeld()
    {
        if (_closing || _saves is null)
        {
            return;
        }

        _ = _saves.Save(SessionSnapshot());
        _workbench.SaveUnsavedSettings();
    }

    // A running query does not hold a sign-out: stopping it is the default the shutdown guidance asks for.
    private string? ShutdownBlockReason()
    {
        if (_closing)
        {
            return null;
        }

        var pending = AllWindows
            .SelectMany(window => window._open)
            .Aggregate(PendingWork.None, (all, open) => all.Combine(open.View.Pending()));
        return pending switch
        {
            { UnsavedChanges: true, HeldTransaction: true } => Strings.Get("ShutdownBlockedBoth"),
            { UnsavedChanges: true } => Strings.Get("ShutdownBlockedUnsaved"),
            { HeldTransaction: true } => Strings.Get("ShutdownBlockedTransaction"),
            _ => null,
        };
    }

    private SessionState SessionSnapshot()
    {
        var connections = _open.Select(open => Persisted(open.Snapshot())).ToList();
        var front = _front is null ? (connections.Count > 0 ? 0 : -1) : _open.IndexOf(_front);
        var windows = _tabWindows
            .Where(window => window._front is not null)
            .Select(window => new TabWindowState
            {
                Connection = Persisted(window._front!.Snapshot()),
                Placement = WindowInterop.Placement(window),
            })
            .Where(window => window.Connection.Tabs.Count > 0)
            .ToList();
        return new SessionState
        {
            Connections = connections,
            Front = front,
            Window = WindowInterop.Placement(this),
            ObjectPaneWidth = _workbench.ObjectPaneWidth,
            TabWindows = windows,
        };
    }

    // Only session.json leaves definition tabs out; a reconnect and a tab window keep them.
    private static SessionConnection Persisted(SessionConnection connection)
    {
        var (tabs, selected) = SessionTabs.Persisted(connection.Tabs, connection.SelectedTab);
        return connection with { Tabs = tabs, SelectedTab = selected };
    }

    private void UpdateCommands()
    {
        var workspace = Workspace;
        var tab = workspace?.ActiveTab;
        var front = Rail.Content is WorkspaceView ? _front : null;
        MenuNewQueryTab.IsEnabled = workspace is not null;
        MenuCloseTab.IsEnabled = tab is not null;
        MenuReopenTab.IsEnabled = workspace?.CanReopenTab ?? false;
        MenuMoveTab.IsEnabled = workspace?.CanMoveActiveTab ?? false;
        MenuShowObjects.IsEnabled = workspace is not null;
        MenuShowObjects.IsChecked = workspace?.ObjectsVisible ?? true;
        MenuFilterObjects.IsEnabled = workspace is not null;
        MenuShowHistory.IsEnabled = workspace is not null;
        MenuShowHistory.IsChecked = workspace?.HistoryVisible ?? false;
        MenuExportResults.IsEnabled = workspace?.CanExport ?? false;
        MenuShareResult.IsEnabled = workspace?.CanShareResult ?? false;
        MenuShareQuery.IsEnabled = workspace?.CanShareQuery ?? false;
        MenuRefresh.IsEnabled = workspace is not null;
        MenuEditConnection.IsEnabled = front?.ConnectionId is not null;
        MenuReconnect.IsEnabled = front is { State: ConnectionState.Connected or ConnectionState.Failed };
        MenuDisconnect.IsEnabled = front is not null;
        // A definition tab reads its text with Reload, not Run, and has nothing to stop.
        MenuRun.IsEnabled = tab is QueryTabView { IsRunning: false } or TableTabView { IsRunning: false };
        MenuRunStatement.IsEnabled = tab is QueryTabView { IsRunning: false };
        MenuStop.IsEnabled = tab is QueryTabView { IsRunning: true } or TableTabView { IsRunning: true };
        var editor = tab?.Editor is not null;
        foreach (var item in new[] { MenuUndo, MenuRedo, MenuCut, MenuPaste, MenuFind })
        {
            item.IsEnabled = editor;
        }

        MenuCopy.IsEnabled = tab is not null;
        MenuSelectAll.IsEnabled = tab is not null;
        // A query tab never edits; a table tab says what its page can do now.
        var table = tab as TableTabView;
        MenuFilterRows.IsEnabled = table is not null;
        MenuSaveChanges.IsEnabled = table is { CanSave: true };
        MenuDiscardChanges.IsEnabled = table is { CanDiscard: true };
        MenuPreviewSql.IsEnabled = table is { CanPreview: true };
        MenuAddRow.IsEnabled = table is { CanAddRow: true };
        MenuDuplicateRow.IsEnabled = table is { CanChangeRows: true };
        MenuDeleteRows.IsEnabled = table is { CanChangeRows: true };
        _primary._sessionEnd?.Update();
    }

    private void OnNewConnection(object sender, RoutedEventArgs e) => NewConnection();

    private async void OnOpenFile(object sender, RoutedEventArgs e) => await OpenFileAsync();

    private async void OnImport(object sender, RoutedEventArgs e) => await ImportAsync();

    private void OnNewQueryTab(object sender, RoutedEventArgs e) => Workspace?.NewQueryTab();

    private void OnCloseTab(object sender, RoutedEventArgs e) => Workspace?.CloseActiveTab();

    private void OnReopenTab(object sender, RoutedEventArgs e) => Workspace?.ReopenClosedTab();

    private void OnMoveTab(object sender, RoutedEventArgs e) => Workspace?.MoveActiveTabToNewWindow();

    private void OnShowSettings(object sender, RoutedEventArgs e) => ShowSettings();

    // Exit ends the app from any window; the primary saves every window as it closes.
    private async void OnExit(object sender, RoutedEventArgs e) => await _primary.RequestCloseAsync();

    private void OnUndo(object sender, RoutedEventArgs e) => EditorKey(VirtualKey.Z);

    private void OnRedo(object sender, RoutedEventArgs e) => EditorKey(VirtualKey.Y);

    private void OnCut(object sender, RoutedEventArgs e) => Workspace?.ActiveTab?.Editor?.Cut();

    private async void OnCopy(object sender, RoutedEventArgs e)
    {
        switch (Workspace?.ActiveTab)
        {
            case { MessagesTarget: { } messages }:
                messages.CopySelectionToClipboard();
                break;
            case { GridIsTarget: true, Grid: { } grid }:
                await grid.CopySelectionAsync();
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
        if (Workspace?.ActiveTab?.MessagesTarget is { } messages)
        {
            messages.SelectAll();
            messages.Focus(FocusState.Programmatic);
            return;
        }

        if (Workspace?.ActiveTab is { GridIsTarget: true, Grid: { } grid })
        {
            grid.SelectAll();
            grid.Focus(FocusState.Programmatic);
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
        if (_home is null)
        {
            _primary.Activate();
            _primary.OnShowConnections(sender, e);
            return;
        }

        ShowHome();
        _home.FocusSearch();
    }

    private void OnToggleObjects(object sender, RoutedEventArgs e)
    {
        Workspace?.ToggleObjects();
        UpdateCommands();
    }

    private void OnFilterObjects(object sender, RoutedEventArgs e) => Workspace?.FocusFilter();

    private async void OnToggleHistory(object sender, RoutedEventArgs e)
    {
        if (Workspace is { } workspace)
        {
            await workspace.ToggleHistoryAsync();
        }

        UpdateCommands();
    }

    private async void OnExportResults(object sender, RoutedEventArgs e)
    {
        if (Workspace is { } workspace)
        {
            await workspace.ExportAsync();
        }
    }

    private void OnFilterRows(object sender, RoutedEventArgs e) => (Workspace?.ActiveTab as TableTabView)?.ToggleFilter();

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
        if (_front is { } open && await ConfirmDisconnectAsync(open))
        {
            _primary.DropSpare();
            await open.DisconnectAsync(keepTabs: true);
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

    private void OnRunStatement(object sender, RoutedEventArgs e) => (Workspace?.ActiveTab as QueryTabView)?.RunStatement();

    private void OnStop(object sender, RoutedEventArgs e) => Workspace?.ActiveTab?.Stop();

    private async void OnSaveChanges(object sender, RoutedEventArgs e)
    {
        if (Workspace?.ActiveTab is TableTabView table)
        {
            await table.SaveAsync();
        }
    }

    private async void OnDiscardChanges(object sender, RoutedEventArgs e)
    {
        if (Workspace?.ActiveTab is TableTabView table)
        {
            await table.DiscardAsync();
        }
    }

    private async void OnPreviewSql(object sender, RoutedEventArgs e)
    {
        if (Workspace?.ActiveTab is TableTabView table)
        {
            await table.PreviewAsync();
        }
    }

    private void OnAddRow(object sender, RoutedEventArgs e) => (Workspace?.ActiveTab as TableTabView)?.AddRow();

    private void OnDuplicateRow(object sender, RoutedEventArgs e) => (Workspace?.ActiveTab as TableTabView)?.DuplicateRows();

    private void OnDeleteRows(object sender, RoutedEventArgs e) => (Workspace?.ActiveTab as TableTabView)?.DeleteRows();

    private async void OnDocumentation(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(SettingsView.DocumentationUri);

    private async void OnReportIssue(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(SettingsView.IssuesUri);

    private async void OnOpenSample(object sender, RoutedEventArgs e) => await OpenSampleAsync();

    private void OnAbout(object sender, RoutedEventArgs e)
    {
        ShowSettings();
        _primary.Settings().ShowAbout();
    }
}
