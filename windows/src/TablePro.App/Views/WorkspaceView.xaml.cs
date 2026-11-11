using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Editor.Model;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

internal sealed record SecretAnswer(string Secret, bool Save)
{
    // A record's ToString prints every property, and this one holds a password.
    private bool PrintMembers(System.Text.StringBuilder builder)
    {
        builder.Append("Secret = [REDACTED], Save = ").Append(Save);
        return true;
    }
}

public sealed partial class WorkspaceView : UserControl
{
    private readonly Workbench _workbench;
    private readonly OpenConnection _connection;
    private SessionShare? _share;
    private DatabaseSession? _session;
    private IReadOnlyList<ObjectEntry>? _everyObject;
    private bool _singleSchema;
    private string _failureDetails = string.Empty;
    private int _filterGeneration;

    // Schemas a refresh reads again, the next time each one opens.
    private readonly HashSet<string> _stale = [];
    private readonly ClosedTabs _closed = new();

    // What each query tab's text read at its document's version, since the session is written every few seconds.
    private readonly Dictionary<ITabContent, (long Version, LineEnding Ending, SessionTab Tab)> _snapshots = [];
    private readonly HashSet<TabViewItem> _closingTabs = [];
    private CancellationTokenSource? _watching;
    private Windows.Foundation.Point _stripOrigin;
    private WindowId _tearOutWindow;
    private CancellationTokenSource? _recoveringHostKey;
    private HostKeyFailure? _hostKeyFailure;

    internal WorkspaceView(Workbench workbench, OpenConnection connection)
    {
        _workbench = workbench;
        _connection = connection;
        InitializeComponent();
        ObjectList.ContainerContentChanging += OnObjectContainerChanging;
        for (var number = 1; number <= 9; number++)
        {
            var position = number;
            var accelerator = new KeyboardAccelerator
            {
                Key = VirtualKey.Number0 + number,
                Modifiers = VirtualKeyModifiers.Control,
            };
            accelerator.Invoked += (_, args) =>
            {
                args.Handled = SelectTab(position);
            };
            KeyboardAccelerators.Add(accelerator);
        }

        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        ApplyPaneWidth();
        Tabs.Loaded += (_, _) => UpdateTearOut();
        Tabs.LayoutUpdated += OnTabsLayoutUpdated;
    }

    public event EventHandler? EditRequested;

    public event EventHandler? CommandsChanged;

    // The user closed the last tab; a window a tab was moved into closes with it.
    public event EventHandler? Emptied;

    // Something session.json keeps changed: a tab, its text, its page, the one selected or the pane's width.
    public event EventHandler? SessionChanged;

    internal IWorkspaceHost? Host { get; set; }

    public int TabCount => Tabs.TabItems.Count;

    // A tab may leave a window that keeps another, or the window with the rail.
    public bool CanMoveActiveTab => Host is { CanMoveTabs: true } && ActiveTab is not null && (Host is { IsPrimary: true } || TabCount > 1);

    public ObservableCollection<ObjectNode> Objects { get; } = [];

    public bool IsConnected => _session is not null;

    public bool ObjectsVisible => ObjectsPane.Visibility == Visibility.Visible;

    public bool CanReopenTab => _session is not null && _closed.Count > 0;

    internal ITabContent? ActiveTab => (Tabs.SelectedItem as TabViewItem)?.Content as ITabContent;

    // Every workspace shares the width the last one was given.
    public void ApplyPaneWidth()
    {
        if (ObjectsVisible)
        {
            ObjectsColumn.Width = new GridLength(_workbench.ObjectPaneWidth);
        }
    }

    internal CredentialDialogs CredentialPrompter => new CredentialDialogs(this);

    internal async Task<SecretAnswer?> AskSecretAsync(SecretKind kind, CancellationToken cancellationToken)
    {
        PromptPurpose purpose = kind switch
        {
            SecretKind.SshPassword => new PromptPurpose.SshPassword(PromptReason.NotStored),
            SecretKind.SshPassphrase => new PromptPurpose.SshPassphrase(string.Empty, PromptReason.NotStored),
            _ => new PromptPurpose.DatabasePassword(PromptReason.NotStored),
        };
        var answer = await CredentialPrompter.PromptAsync(new CredentialPrompt(
            purpose, _connection.Name, [new PromptField(string.Empty, true)], true), cancellationToken).ConfigureAwait(true);
        return answer is { Values.Count: 1 } ? new SecretAnswer(answer.Values[0], answer.Remember) : null;
    }

    public void Rename(string name)
    {
        if (ConnectingPanel.Visibility == Visibility.Visible)
        {
            ConnectingText.Text = Strings.Format("ConnectingTo", name);
        }
    }

    public void ShowConnecting()
    {
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        FailedPanel.Visibility = Visibility.Collapsed;
        FailureBar.IsOpen = false;
        ConnectingPanel.Visibility = Visibility.Visible;
        ConnectingRing.IsActive = true;
        ConnectingText.Text = Strings.Format("ConnectingTo", _connection.Name);
        CancelConnectButton.Focus(FocusState.Programmatic);
    }

    public void ShowFailed(string message, string details)
    {
        _failureDetails = details;
        ConnectingRing.IsActive = false;
        ConnectingPanel.Visibility = Visibility.Collapsed;
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        FailedPanel.Visibility = Visibility.Visible;
        EditConnectionButton.Visibility = _connection.ConnectionId is null ? Visibility.Collapsed : Visibility.Visible;
        FailureBar.Title = Strings.Format("ConnectFailedTitle", _connection.Name);
        FailureBar.Message = message;
        // Narrator reads an InfoBar when it opens, not when its text changes, so it opens again.
        FailureBar.IsOpen = false;
        FailureBar.IsOpen = true;
        RetryButton.Focus(FocusState.Programmatic);
    }

    // A workspace a tab is moved into starts with none, and reads its tree once the tab is there (Start).
    internal void ShowConnected(SessionShare share, SessionConnection? restore, bool adopted = false)
    {
        _share = share;
        _session = share.Session;
        _everyObject = null;
        ConnectingRing.IsActive = false;
        ConnectingPanel.Visibility = Visibility.Collapsed;
        FailedPanel.Visibility = Visibility.Collapsed;
        WorkspaceGrid.Visibility = Visibility.Visible;
        if (adopted)
        {
            UpdateTearOut();
            CommandsChanged?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (restore is { Tabs.Count: > 0 })
        {
            foreach (var tab in restore.Tabs)
            {
                if (tab is { Kind: TabKind.Table, Table: { } table })
                {
                    // Tabs merged from two windows can show one table twice; each comes back.
                    AddTable(tab.Schema, table, null, tab);
                }
                else
                {
                    NewQueryTab(tab.Sql, tab.Title);
                }
            }

            SelectTab(Math.Clamp(restore.SelectedTab, 0, Tabs.TabItems.Count - 1) + 1);
        }
        else
        {
            NewQueryTab();
        }

        Start();
    }

    public async void Start()
    {
        if (_session is not { } session)
        {
            return;
        }

        UpdateTearOut();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        WatchHealth(session);
        await LoadTreeAsync().ConfigureAwait(true);
    }

    public SessionConnection Snapshot(SessionConnection origin)
    {
        ArgumentNullException.ThrowIfNull(origin);
        // Until it connects, the tabs it was saved with are still to come; once connected, the strip is the truth.
        if (_session is null)
        {
            return origin;
        }

        var tabs = Tabs.TabItems.OfType<TabViewItem>()
            .Select(item => item.Content)
            .OfType<ITabContent>()
            .Select(SnapshotOf)
            .ToList();
        return origin with { Tabs = tabs, SelectedTab = Math.Max(0, Tabs.SelectedIndex) };
    }

    // A query tab's snapshot is its fixed title and its text, so the text is copied out again only once it changed.
    private SessionTab SnapshotOf(ITabContent content)
    {
        if (content.Editor?.Document is not { } document)
        {
            return content.Snapshot();
        }

        if (_snapshots.TryGetValue(content, out var kept)
            && kept.Version == document.Version
            && kept.Ending == document.LineEnding)
        {
            return kept.Tab;
        }

        var tab = content.Snapshot();
        _snapshots[content] = (document.Version, document.LineEnding, tab);
        return tab;
    }

    internal bool HasUnconfirmedTransactions(ISet<ITabContent> confirmed) => Tabs.TabItems.OfType<TabViewItem>()
        .Any(item => item.Content is ITabContent content && WorkspaceNotices.Holds(content.Transaction) && !confirmed.Contains(content));

    // A table tab loading a page is not work the user started, so only a query tab's run is asked about.
    internal List<ITabContent> RunningQueries() => [.. Tabs.TabItems.OfType<TabViewItem>()
        .Select(item => item.Content)
        .OfType<QueryTabView>()
        .Where(view => view.IsRunning)];

    // The tabs of a window that closed, so Reopen closed tab brings them back here in their order.
    internal void KeepClosed(IReadOnlyList<SessionTab> tabs)
    {
        ArgumentNullException.ThrowIfNull(tabs);
        for (var index = tabs.Count - 1; index >= 0; index--)
        {
            _closed.Push(tabs[index], int.MaxValue);
        }

        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    internal async Task<bool> ConfirmCloseAsync(ISet<ITabContent> confirmed)
    {
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>().ToList())
        {
            if (item.Content is ITabContent content && WorkspaceNotices.Holds(content.Transaction) && !confirmed.Contains(content))
            {
                Tabs.SelectedItem = item;
                if (!await ConfirmCloseHeldAsync(content).ConfigureAwait(true))
                {
                    return false;
                }

                confirmed.Add(content);
            }
        }

        return true;
    }

    // A reconnect keeps the closed tabs, which hold only their text or table, to reopen on the next session.
    public async Task CloseTabsAsync(bool keepClosed = false)
    {
        CancelRecovery();
        _hostKeyFailure = null;
        // A pending individual close must not create a replacement while disconnect is awaiting it.
        _share = null;
        _session = null;
        Tabs.CanTearOutTabs = false;
        _watching?.Cancel();
        _watching = null;
        HealthBar.IsOpen = false;
        ElsewhereBar.IsOpen = false;
        HideChangesOnConnect();
        if (!keepClosed)
        {
            _closed.Clear();
        }

        foreach (var content in Tabs.TabItems.OfType<TabViewItem>().Select(item => item.Content).OfType<ITabContent>().ToList())
        {
            await content.CloseAsync().ConfigureAwait(true);
        }

        Tabs.TabItems.Clear();
        _snapshots.Clear();
        Objects.Clear();
        ObjectList.ItemsSource = null;
        _everyObject = null;
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void NewQueryTab(string? sql = null, string? title = null)
    {
        if (_share is null)
        {
            return;
        }

        AddTab(new QueryTabView(_workbench, _share, title ?? NextQueryTitle(), sql), Symbol.Document);
    }

    public void OpenTable(string? schema, string name, int? index = null, SessionTab? restore = null)
    {
        if (_share is null)
        {
            return;
        }

        var open = Tabs.TabItems.OfType<TabViewItem>()
            .FirstOrDefault(item => item.Content is TableTabView view && view.Shows(schema, name));
        if (open is not null)
        {
            Tabs.SelectedItem = open;
            return;
        }

        AddTable(schema, name, index, restore);
    }

    private void AddTable(string? schema, string name, int? index, SessionTab? restore)
    {
        if (_share is null)
        {
            return;
        }

        var table = new TableTabView(_workbench, _share, schema, name, restore);
        AddTab(table, Symbol.ViewAll, index);
        table.Run();
    }

    public void CloseActiveTab()
    {
        if (Tabs.SelectedItem is TabViewItem item)
        {
            _ = CloseTabAsync(item);
        }
    }

    public void ToggleObjects()
    {
        var show = !ObjectsVisible;
        ObjectsPane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ObjectsSplitter.Visibility = ObjectsPane.Visibility;
        // A hidden pane's column has no width to keep, so its limits go with it.
        ObjectsColumn.MinWidth = show ? ObjectPane.MinWidth : 0;
        ObjectsColumn.Width = show ? new GridLength(_workbench.ObjectPaneWidth) : new GridLength(0);
    }

    public void ReopenClosedTab()
    {
        if (_share is null || _closed.Pop() is not { } closed)
        {
            return;
        }

        var index = Math.Min(closed.Index, Tabs.TabItems.Count);
        if (closed.Tab is { Kind: TabKind.Table, Table: { } table })
        {
            AddTable(closed.Tab.Schema, table, index, closed.Tab);
        }
        else
        {
            AddTab(new QueryTabView(_workbench, _share, closed.Tab.Title, closed.Tab.Sql), Symbol.Document, index);
        }

        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void FocusFilter()
    {
        if (!ObjectsVisible)
        {
            ToggleObjects();
        }

        ObjectFilter.Focus(FocusState.Keyboard);
    }

    public async Task RefreshAsync()
    {
        if (_session is null)
        {
            return;
        }

        _everyObject = null;
        await LoadTreeAsync(refresh: true).ConfigureAwait(true);
    }

    private bool SelectTab(int position)
    {
        var count = Tabs.TabItems.Count;
        if (count == 0)
        {
            return false;
        }

        // Ctrl+9 goes to the last tab, as in a browser.
        var index = position == 9 ? count - 1 : position - 1;
        if (index >= count)
        {
            return false;
        }

        Tabs.SelectedIndex = index;
        return true;
    }

    private string NextQueryTitle()
    {
        var taken = Tabs.TabItems.OfType<TabViewItem>()
            .Select(item => item.Content)
            .OfType<QueryTabView>()
            .Select(view => view.Title)
            .ToHashSet(StringComparer.CurrentCulture);
        for (var number = 1; ; number++)
        {
            var title = Strings.Format("QueryTabTitle", number);
            if (!taken.Contains(title))
            {
                return title;
            }
        }
    }

    private void AddTab(ITabContent content, Symbol icon, int? index = null)
    {
        var item = new TabViewItem
        {
            Header = content.Title,
            IconSource = new SymbolIconSource { Symbol = icon },
            Content = content,
        };
        Take(item, index);
    }

    // The workspace whose strip a tab is in, which moves with the tab between windows.
    internal static WorkspaceView? HolderOf(TabViewItem tab) => tab.Tag as WorkspaceView;

    internal void Take(TabViewItem item, int? index = null)
    {
        item.Tag = this;
        item.ContextRequested += OnTabContextRequested;
        if (item.Content is ITabContent content)
        {
            content.StateChanged += OnTabStateChanged;
            if (content.Editor is { } editor)
            {
                editor.TextChanged += OnEditorTextChanged;
            }
        }

        if (index is { } at && at >= 0 && at <= Tabs.TabItems.Count)
        {
            Tabs.TabItems.Insert(at, item);
        }
        else
        {
            Tabs.TabItems.Add(item);
        }

        Tabs.SelectedItem = item;
        UpdateElsewhereBar();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    // The tab keeps its content, its connection and its run; only this workspace lets go of it.
    internal void Release(TabViewItem item)
    {
        item.ContextRequested -= OnTabContextRequested;
        if (item.Content is ITabContent content)
        {
            content.StateChanged -= OnTabStateChanged;
            if (content.Editor is { } editor)
            {
                editor.TextChanged -= OnEditorTextChanged;
            }

            _snapshots.Remove(content);
        }

        Tabs.TabItems.Remove(item);
        // Native tear-out cannot drop back into an empty primary strip.
        if (Tabs.TabItems.Count == 0 && Host is { IsPrimary: true })
        {
            NewQueryTab();
        }

        UpdateElsewhereBar();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void MoveActiveTabToNewWindow()
    {
        if (CanMoveActiveTab && Tabs.SelectedItem is TabViewItem item)
        {
            Host?.MoveToNewWindow(item);
        }
    }

    // Before the workspace leaves its window, while TabView can still reach the window to unmark its strip.
    public void Leave() => Tabs.CanTearOutTabs = false;

    internal void UpdateTearOut()
    {
        Tabs.CanTearOutTabs = false;
        if (Tabs.IsLoaded && _session is not null && Host is { CanMoveTabs: true })
        {
            Tabs.CanTearOutTabs = true;
            _stripOrigin = Tabs.TransformToVisual(null).TransformPoint(default);
        }
    }

    // TabView marks its strip as the window's caption, to drag tabs out, and marks it again only when the strip
    // resizes; a bar opening above it or the object pane resizing moves it, so it is set again to mark the new place.
    private void OnTabsLayoutUpdated(object? sender, object e)
    {
        if (!Tabs.CanTearOutTabs || !Tabs.IsLoaded)
        {
            return;
        }

        var origin = Tabs.TransformToVisual(null).TransformPoint(default);
        if (!origin.Equals(_stripOrigin))
        {
            _stripOrigin = origin;
            Tabs.CanTearOutTabs = false;
            Tabs.CanTearOutTabs = true;
        }
    }

    private void OnTabStateChanged(object? sender, EventArgs e)
    {
        UpdateElsewhereBar();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnEditorTextChanged(object? sender, EventArgs e) => SessionChanged?.Invoke(this, EventArgs.Empty);

    // Built when asked for, since a menu keeps the window it first opened in and a tab can move to another.
    private void OnTabContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (sender is not TabViewItem item)
        {
            return;
        }

        args.Handled = true;
        ShowTabContextMenu(item, args.TryGetPosition(item, out var point) ? point : null);
    }

    internal bool ShowTabContextMenu(Windows.Graphics.PointInt32 screenPoint)
    {
        var point = XamlRoot.CoordinateConverter.ConvertScreenToLocal(screenPoint);
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>().Where(item => item.IsLoaded))
        {
            var bounds = item.TransformToVisual(null).TransformBounds(
                new Windows.Foundation.Rect(0, 0, item.ActualWidth, item.ActualHeight));
            if (bounds.Contains(point))
            {
                ShowTabContextMenu(item, XamlRoot.Content.TransformToVisual(item).TransformPoint(point));
                return true;
            }
        }

        return false;
    }

    private void ShowTabContextMenu(TabViewItem item, Windows.Foundation.Point? position)
    {
        Tabs.SelectedItem = item;
        var menu = new MenuFlyout();
        var move = new MenuFlyoutItem
        {
            Text = Strings.Get("MenuMoveToNewWindow"),
            Icon = new SymbolIcon(Symbol.NewWindow),
            IsEnabled = CanMoveActiveTab,
        };
        move.Click += (_, _) => Host?.MoveToNewWindow(item);
        var close = new MenuFlyoutItem { Text = Strings.Get("MenuCloseThisTab"), Icon = new SymbolIcon(Symbol.Cancel) };
        close.Click += async (_, _) => await CloseTabAsync(item).ConfigureAwait(true);
        menu.Items.Add(move);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(close);
        if (position is { } point)
        {
            menu.ShowAt(item, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt(item);
        }
    }

    // Each press on a tab may start a drag out of the strip, so the window is asked for before any drag.
    private void OnTabTearOutWindowRequested(TabView sender, TabViewTabTearOutWindowRequestedEventArgs args)
    {
        if (Host is { } host)
        {
            _tearOutWindow = host.TearOutWindow(_connection);
            args.NewWindowId = _tearOutWindow;
        }
    }

    private void OnTabTearOutRequested(TabView sender, TabViewTabTearOutRequestedEventArgs args)
    {
        foreach (var tab in args.Tabs.OfType<TabViewItem>())
        {
            // WinUI 2.6.4 leaves this event's NewWindowId empty; retain the window supplied at drag start.
            Host?.TearOut(tab, _tearOutWindow);
        }
    }

    private void OnExternalTornOutTabsDropping(TabView sender, TabViewExternalTornOutTabsDroppingEventArgs args) =>
        args.AllowDrop = Host is { AcceptsTabs: true } && args.Tabs.OfType<TabViewItem>().All(Accepts);

    // A tab keeps the connection it was opened on, so it joins only a workspace of that connection.
    private bool Accepts(TabViewItem tab) =>
        HolderOf(tab) is { } source
        && _connection.Matches(source._connection.ConnectionId, source._connection.Origin.FilePath)
        && !(source.Host is { IsPrimary: true } && source.TabCount == 1);

    private void OnExternalTornOutTabsDropped(TabView sender, TabViewExternalTornOutTabsDroppedEventArgs args)
    {
        var index = args.DropIndex;
        foreach (var tab in args.Tabs.OfType<TabViewItem>())
        {
            if (HolderOf(tab) is { } source)
            {
                // The drag can leave this strip again before the pointer is released.
                _tearOutWindow = source.XamlRoot.ContentIslandEnvironment.AppWindowId;
                source.Release(tab);
            }

            Take(tab, index++);
        }
    }

    // Closing a tab ends its own connection, and its transaction with it, so a held one is asked about first.
    // A second request while the first is closing the tab, or asking about its transaction, does nothing.
    private async Task CloseTabAsync(TabViewItem item)
    {
        if (!_closingTabs.Add(item))
        {
            return;
        }

        try
        {
            if (item.Content is ITabContent content)
            {
                if (WorkspaceNotices.Holds(content.Transaction) && !await ConfirmCloseHeldAsync(content).ConfigureAwait(true))
                {
                    return;
                }

                _closed.Push(content.Snapshot(), Tabs.TabItems.IndexOf(item));
                await content.CloseAsync().ConfigureAwait(true);
            }
        }
        finally
        {
            _closingTabs.Remove(item);
        }

        Release(item);
        if (Tabs.TabItems.Count == 0)
        {
            Emptied?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task<bool> ConfirmCloseHeldAsync(ITabContent content)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Format("CloseHeldTabTitle", content.Title),
            Content = Strings.Get("CloseHeldTabMessage"),
            PrimaryButtonText = Strings.Get("CloseHeldTabButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, this) == ContentDialogResult.Primary;
    }

    // A saved change only a new connection takes, kept back because a held transaction would go with this one.
    internal void ShowChangesOnConnect(bool asksBeforeWrites)
    {
        ChangesBar.Title = Strings.Get("ChangesOnConnectTitle");
        ChangesBar.Message = asksBeforeWrites ? Strings.Get("ChangesOnConnectAsks") : string.Empty;
        // A closed InfoBar keeps its margin, so the bar is collapsed while it is closed.
        ChangesBar.Visibility = Visibility.Visible;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        ChangesBar.IsOpen = false;
        ChangesBar.IsOpen = true;
    }

    internal void HideChangesOnConnect()
    {
        ChangesBar.IsOpen = false;
        ChangesBar.Visibility = Visibility.Collapsed;
    }

    // The tab shown names its own transaction; this bar names one another tab holds.
    private void UpdateElsewhereBar()
    {
        var tabs = new List<HeldTab>();
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
        {
            if (item.Content is ITabContent content)
            {
                tabs.Add(new HeldTab(content.Title, content.Transaction, ReferenceEquals(item, Tabs.SelectedItem)));
            }
        }

        if (WorkspaceNotices.Elsewhere(tabs) is not { } elsewhere)
        {
            ElsewhereBar.IsOpen = false;
            return;
        }

        var message = elsewhere.Count > 1
            ? Strings.Format("TransactionElsewhereMany", elsewhere.Count)
            : Strings.Format(
                elsewhere.Transaction == TransactionState.Failed ? "TransactionElsewhereFailed" : "TransactionElsewhere",
                elsewhere.Title);
        ShowTransactionTabButton.Tag = elsewhere.Target;
        if (!ElsewhereBar.IsOpen || ElsewhereBar.Message != message)
        {
            ElsewhereBar.Message = message;
            // Narrator reads an InfoBar when it opens, not when its text changes.
            ElsewhereBar.IsOpen = false;
            ElsewhereBar.IsOpen = true;
        }
    }

    private void OnShowTransactionTab(object sender, RoutedEventArgs e)
    {
        if (ShowTransactionTabButton.Tag is int target && target < Tabs.TabItems.Count)
        {
            Tabs.SelectedIndex = target;
        }
    }

    private async void WatchHealth(DatabaseSession session)
    {
        _watching?.Cancel();
        using var watching = new CancellationTokenSource();
        _watching = watching;
        var health = session.Health;
        ShowHealth(health);
        try
        {
            while (!watching.IsCancellationRequested)
            {
                health = await session.WaitForHealthChangeAsync(health, watching.Token).ConfigureAwait(true);
                if (!ReferenceEquals(_session, session) || watching.IsCancellationRequested)
                {
                    break;
                }

                ShowHealth(health);
            }
        }
        catch (Exception exception) when (exception is TableProException or OperationCanceledException or ObjectDisposedException)
        {
            // The session closed, or the workspace stopped watching it.
        }
        finally
        {
            if (ReferenceEquals(_watching, watching))
            {
                _watching = null;
            }
        }
    }

    private void ShowHealth(SessionHealth health)
    {
        var hostKey = health is SessionHealth.Failed { Reason.HostKey: { TrustAllowed: true } failure }
            ? failure : null;
        if (hostKey != _hostKeyFailure)
        {
            CancelRecovery();
            _hostKeyFailure = hostKey;
        }

        if (WorkspaceNotices.For(health) is not { } notice)
        {
            HealthBar.IsOpen = false;
            return;
        }

        HealthBar.Severity = notice.Kind == HealthNoticeKind.Failed ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
        HealthBar.Title = notice.Kind switch
        {
            HealthNoticeKind.Reconnecting => Strings.Format("HealthReconnecting", notice.Attempt),
            HealthNoticeKind.Offline => Strings.Get("HealthOffline"),
            _ => Strings.Get("HealthFailed"),
        };
        HealthBar.Message = notice.Reason is { } reason ? Strings.Error(reason) : string.Empty;
        ReconnectButton.Visibility = notice.OffersReconnect ? Visibility.Visible : Visibility.Collapsed;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        HealthBar.IsOpen = false;
        HealthBar.IsOpen = true;
    }

    internal void CancelRecovery() => _recoveringHostKey?.Cancel();

    private async void OnReconnect(object sender, RoutedEventArgs e)
    {
        var session = _session;
        if (session is null || _recoveringHostKey is not null)
        {
            return;
        }

        if (_hostKeyFailure is not { } failure || _connection.ConnectionId is not { } id)
        {
            session.Reconnect();
            return;
        }

        using var recovering = new CancellationTokenSource();
        _recoveringHostKey = recovering;
        ReconnectButton.IsEnabled = false;
        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
            recovering.Token.ThrowIfCancellationRequested();
            var saved = snapshot.Connections.FirstOrDefault(connection => connection.Id == id);
            if (saved is null || !await CredentialPrompter.RecoverHostKeyAsync(
                _workbench.Core, saved, failure, recovering.Token).ConfigureAwait(true))
            {
                return;
            }

            recovering.Token.ThrowIfCancellationRequested();
            if (ReferenceEquals(_session, session) && _hostKeyFailure == failure)
            {
                session.Reconnect();
            }
        }
        catch (OperationCanceledException)
        {
            // Closing the workspace or a new health state ends this recovery attempt.
        }
        catch (TableProException exception)
        {
            if (ReferenceEquals(_session, session) && !recovering.IsCancellationRequested)
            {
                HealthBar.Message = Strings.Error(exception.Error);
            }
        }
        finally
        {
            if (ReferenceEquals(_recoveringHostKey, recovering))
            {
                _recoveringHostKey = null;
                ReconnectButton.IsEnabled = true;
            }
        }
    }

    private void OnObjectsPaneSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (ObjectsVisible && e.NewSize.Width > 0)
        {
            _workbench.ObjectPaneWidth = ObjectPane.Clamp(e.NewSize.Width);
            SessionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task LoadTreeAsync(bool refresh = false)
    {
        var session = _session;
        if (session is null)
        {
            return;
        }

        try
        {
            var schemas = await session.GetSchemasAsync().ConfigureAwait(true);
            var shown = schemas.Where(schema => !schema.IsSystem).ToList();
            if (shown.Count == 0)
            {
                shown = [.. schemas];
            }

            Objects.Clear();
            _singleSchema = shown.Count <= 1;
            if (_singleSchema)
            {
                var objects = refresh
                    ? await session.RefreshObjectsAsync(ObjectScope.DefaultSchema).ConfigureAwait(true)
                    : await session.GetObjectsAsync(ObjectScope.DefaultSchema).ConfigureAwait(true);
                AddFolders(Objects, shown.FirstOrDefault()?.Name, objects);
                foreach (var folder in Objects.Where(node => node.Folder?.Kind == FolderKind.Tables))
                {
                    RealizeFolder(folder);
                    folder.StartsExpanded = true;
                }

                return;
            }

            foreach (var schema in shown.OrderByDescending(schema => schema.IsDefault))
            {
                if (refresh)
                {
                    _stale.Add(schema.Name);
                }

                // The default schema opens, and its objects load when it does.
                Objects.Add(new ObjectNode(ObjectNodeKind.Schema, schema.Name)
                {
                    Icon = Symbol.Folder,
                    Schema = schema.Name,
                    HasUnrealizedChildren = true,
                    StartsExpanded = schema.IsDefault,
                });
            }
        }
        catch (TableProException exception)
        {
            ShowListMessage(Strings.Error(exception.Error));
        }
    }

    // A bound TreeViewItem.IsExpanded is overwritten when the row joins the tree, so a row opens once it has loaded.
    private void OnObjectRowLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is TreeViewItem row && ObjectTree.ItemFromContainer(row) is ObjectNode { StartsExpanded: true } node)
        {
            node.StartsExpanded = false;
            row.IsExpanded = true;
        }
    }

    private async Task RealizeSchemaAsync(ObjectNode node)
    {
        if (_session is null || node.Schema is null)
        {
            return;
        }

        node.HasUnrealizedChildren = false;
        var scope = ObjectScope.Schema(node.Schema);
        var objects = _stale.Remove(node.Schema)
            ? await _session.RefreshObjectsAsync(scope).ConfigureAwait(true)
            : await _session.GetObjectsAsync(scope).ConfigureAwait(true);
        node.Children.Clear();
        AddFolders(node.Children, node.Schema, objects);
    }

    private static void AddFolders(ObservableCollection<ObjectNode> target, string? schema, IReadOnlyList<ObjectEntry> objects)
    {
        foreach (var folder in ObjectFolders.Group(objects))
        {
            target.Add(new ObjectNode(ObjectNodeKind.Folder, Strings.Get("Folder_" + folder.Kind))
            {
                Icon = Symbol.Folder,
                Detail = folder.Objects.Count.ToString(System.Globalization.CultureInfo.CurrentCulture),
                Schema = schema,
                Folder = folder,
                HasUnrealizedChildren = folder.Objects.Count > 0,
            });
        }
    }

    // TreeView realizes a container per item, so a folder holds its first page; the rest is a list away.
    private static void RealizeFolder(ObjectNode node)
    {
        if (node.Folder is not { } folder || !node.HasUnrealizedChildren)
        {
            return;
        }

        node.HasUnrealizedChildren = false;
        foreach (var entry in folder.Objects.Take(ObjectFolders.PageSize))
        {
            node.Children.Add(EntryNode(entry, showSchema: false));
        }

        if (folder.Objects.Count > ObjectFolders.PageSize)
        {
            node.Children.Add(new ObjectNode(
                ObjectNodeKind.ShowAll,
                Strings.Format("ShowAllObjects", folder.Objects.Count))
            {
                Icon = Symbol.More,
                Folder = folder,
                Schema = node.Schema,
            });
            node.Children.Add(new ObjectNode(ObjectNodeKind.FilterHint, Strings.Get("TypeToFilter"))
            {
                Icon = Symbol.Find,
            });
        }
    }

    private static ObjectNode EntryNode(ObjectEntry entry, bool showSchema) =>
        new(ObjectNodeKind.Item, entry.Name)
        {
            Entry = entry,
            Schema = entry.Schema,
            Detail = showSchema ? entry.Schema ?? string.Empty : string.Empty,
            Icon = entry.Kind switch
            {
                ObjectKind.View or ObjectKind.MaterializedView => Symbol.View,
                ObjectKind.Sequence => Symbol.Sort,
                ObjectKind.Function or ObjectKind.Procedure => Symbol.Calculator,
                ObjectKind.Trigger => Symbol.Flag,
                ObjectKind.Key => Symbol.Tag,
                _ => Symbol.ViewAll,
            },
        };

    private async void OnTreeExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Item is not ObjectNode node || !node.HasUnrealizedChildren)
        {
            return;
        }

        if (node.Kind == ObjectNodeKind.Schema)
        {
            try
            {
                await RealizeSchemaAsync(node).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                node.HasUnrealizedChildren = true;
                ShowListMessage(Strings.Error(exception.Error));
            }
        }
        else
        {
            RealizeFolder(node);
        }
    }

    private void OnTreeItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not ObjectNode node)
        {
            return;
        }

        switch (node.Kind)
        {
            case ObjectNodeKind.Item:
                Open(node);
                break;
            case ObjectNodeKind.ShowAll when node.Folder is { } folder:
                ShowList(
                    [.. folder.Objects.Select(entry => EntryNode(entry, showSchema: false))],
                    Strings.Format("FolderListHeader", Strings.Get("Folder_" + folder.Kind), folder.Objects.Count));
                break;
            case ObjectNodeKind.FilterHint:
                FocusFilter();
                break;
            default:
                break;
        }
    }

    // A list item's name comes from its container, not from the template inside it.
    private static void OnObjectContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is ObjectNode node)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, node.AccessibleName);
        }
    }

    private void OnObjectListClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is ObjectNode node)
        {
            Open(node);
        }
    }

    private void Open(ObjectNode node)
    {
        if (node.Entry is { } entry && ObjectFolders.HasRows(entry.Kind))
        {
            OpenTable(entry.Schema, entry.Name);
        }
    }

    private async void OnFilterChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        var text = sender.Text;
        var generation = ++_filterGeneration;
        if (string.IsNullOrWhiteSpace(text))
        {
            ShowTree();
            return;
        }

        if (_session is null)
        {
            return;
        }

        try
        {
            _everyObject ??= await _session
                .GetObjectsAsync(_singleSchema ? ObjectScope.DefaultSchema : ObjectScope.AllSchemas)
                .ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            ShowListMessage(Strings.Error(exception.Error));
            return;
        }

        // Typing on while the catalog loads leaves only the newest text to show.
        if (generation != _filterGeneration)
        {
            return;
        }

        var matches = ObjectFolders.Filter(_everyObject, text);
        ShowList(
            [.. matches.Select(entry => EntryNode(entry, showSchema: !_singleSchema))],
            Strings.Format("FilterMatches", matches.Count));
    }

    private void OnBackToTree(object sender, RoutedEventArgs e)
    {
        ObjectFilter.Text = string.Empty;
        ShowTree();
        ObjectTree.Focus(FocusState.Keyboard);
    }

    private void ShowTree()
    {
        ObjectList.ItemsSource = null;
        ObjectList.Visibility = Visibility.Collapsed;
        ListHeader.Visibility = Visibility.Collapsed;
        NoMatchesText.Visibility = Visibility.Collapsed;
        ObjectTree.Visibility = Visibility.Visible;
    }

    private void ShowList(List<ObjectNode> nodes, string header)
    {
        ObjectTree.Visibility = Visibility.Collapsed;
        ObjectList.ItemsSource = nodes;
        ObjectList.Visibility = nodes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NoMatchesText.Text = Strings.Get("NoMatches");
        NoMatchesText.Visibility = nodes.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
        ListHeaderText.Text = header;
        ListHeader.Visibility = Visibility.Visible;
    }

    private void ShowListMessage(string message)
    {
        NoMatchesText.Text = message;
        NoMatchesText.Visibility = Visibility.Visible;
    }

    private void OnAddTab(TabView sender, object args) => NewQueryTab();

    private async void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args) =>
        await CloseTabAsync(args.Tab).ConfigureAwait(true);

    private void OnTabSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ActiveTab?.FocusContent();
        UpdateElsewhereBar();
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnCancelConnect(object sender, RoutedEventArgs e) => _connection.CancelConnect();

    private async void OnRetry(object sender, RoutedEventArgs e) => await _connection.ConnectAsync().ConfigureAwait(true);

    private void OnEditConnection(object sender, RoutedEventArgs e) => EditRequested?.Invoke(this, EventArgs.Empty);

    private void OnCopyDetails(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(_failureDetails);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (COMException)
        {
            // Another program holds the clipboard open; pressing the button again copies once it lets go.
        }
    }
}
