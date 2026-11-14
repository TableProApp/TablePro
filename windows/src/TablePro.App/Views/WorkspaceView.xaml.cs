using System.Collections.ObjectModel;
using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid.Model;
using TablePro.Editor;
using TablePro.Editor.Model;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

// The closing and reopening of tabs is WorkspaceTabs'; the tree, the bars and the strip's moves are drawn here.
public sealed partial class WorkspaceView : UserControl, IWorkspaceTabsView<TabViewItem>
{
    private const double SidePaneWidth = 320;

    private readonly Workbench _workbench;
    private readonly OpenConnection _connection;
    private readonly WorkspaceTabs<TabViewItem> _tabs;
    private SessionShare<DatabaseSession>? _share;
    private DatabaseSession? _session;
    private ObjectCatalog? _everyObject;

    // Bumped as the catalog is dropped, so a read started before a refresh or a reconnect is not kept.
    private int _catalogGeneration;
    private bool _singleSchema;
    private string _failureDetails = string.Empty;
    private int _filterGeneration;
    private CancellationTokenSource? _filtering;

    // Schemas a refresh reads again, the next time each one opens.
    private readonly HashSet<string> _stale = [];

    // What each query tab's text read at its document's version, since the session is written every few seconds.
    private readonly Dictionary<ITabContent, (long Version, LineEnding Ending, SessionTab Tab)> _snapshots = [];
    private CancellationTokenSource? _watching;
    private CancellationTokenSource? _loadingTree;
    private Windows.Foundation.Point _stripOrigin;
    private WindowId _tearOutWindow;
    private CancellationTokenSource? _recoveringHostKey;
    private HostKeyFailure? _hostKeyFailure;

    // The pane reads one connection's runs, so a session of another id builds a new one.
    private HistoryPane? _historyPane;
    private Guid _historyConnection;
    private bool _openingHistory;
    private SavedQueriesPane? _savedPane;
    private bool _openingSaved;

    // Whether each editor held text at its last change, so Save query... follows the shown one going blank or not.
    private readonly Dictionary<SqlEditor, bool> _editorHasText = [];
    private CancellationTokenSource? _exporting;

    internal WorkspaceView(Workbench workbench, OpenConnection connection)
    {
        _workbench = workbench;
        _connection = connection;
        _tabs = new WorkspaceTabs<TabViewItem>(this);
        _tabs.Emptied += (_, _) => Emptied?.Invoke(this, EventArgs.Empty);
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

    public bool CanReopenTab => _session is not null && _tabs.ClosedCount > 0;

    public bool HistoryVisible => SideHost.Visibility == Visibility.Visible && SideHost.Child is HistoryPane;

    public bool SavedQueriesVisible => SideHost.Visibility == Visibility.Visible && SideHost.Child is SavedQueriesPane;

    // A file opened without saving gets a new id each time it opens, so only a saved connection keeps queries.
    public bool CanShowSavedQueries => _connection.ConnectionId is not null;

    // Read on every command update, so only the editor's leading blanks are read.
    public bool CanSaveQuery =>
        _session is not null
        && CanShowSavedQueries
        && ActiveTab is QueryTabView { Editor: { } editor }
        && HasText(editor.Document);

    // One export at a time, of rows the tab shows now.
    // Rows still arriving would be written as if they were all of them.
    public bool CanExport =>
        _exporting is null
        && _session is not null
        && ActiveTab is { IsRunning: false } tab
        && ResultsOf(tab)?.ShownSet is { IsFinished: true };

    // A result still arriving would be shared as if it were all of it.
    public bool CanShareResult => _session is not null && ShareSubjectOf(ActiveTab, ShareKind.Result) is not null;

    // Read on every command update, so the editor's text is read only when the share starts.
    public bool CanShareQuery => _session is not null && ActiveTab is QueryTabView;

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
    internal void ShowConnected(SessionShare<DatabaseSession> share, SessionConnection? restore, bool adopted = false)
    {
        _share = share;
        _session = share.Session;
        ForgetCatalog();
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

        // Tabs merged from two windows can show one table twice; each comes back.
        foreach (var tab in restore?.Tabs ?? [])
        {
            Restore(tab, null);
        }

        // A definition this build cannot read again is left out, which can leave no tab at all.
        if (Tabs.TabItems.Count > 0)
        {
            SelectTab(Math.Clamp(restore?.SelectedTab ?? 0, 0, Tabs.TabItems.Count - 1) + 1);
        }
        else
        {
            NewQueryTab();
        }

        Start();
        if (HistoryVisible)
        {
            _ = ShowHistoryAsync(focus: false);
        }
        else if (SavedQueriesVisible)
        {
            _ = ShowSavedQueriesAsync(focus: false);
        }
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

    // withWork adds each tab's pending work, which only the session file keeps.
    public SessionConnection Snapshot(SessionConnection origin, bool withWork = false)
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
            .Select(content => withWork ? content.WithPendingWork(SnapshotOf(content)) : SnapshotOf(content))
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

    // A held transaction or unsaved changes the close has not been answered about.
    internal bool HasUnconfirmed(ISet<IWorkspaceTab> confirmed) => _tabs.HasUnconfirmed(confirmed);

    internal PendingWork Pending() => _tabs.Pending();

    internal IReadOnlyList<IWorkspaceTab> RunningQueries() => _tabs.RunningQueries();

    internal void KeepClosed(IReadOnlyList<SessionTab> tabs)
    {
        _tabs.KeepClosed(tabs);
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    // Without Save when the connection is being made read only.
    internal Task<bool> ConfirmCloseAsync(ISet<IWorkspaceTab> confirmed, bool offerSave = true) =>
        _tabs.ConfirmCloseAsync(confirmed, offerSave);

    public async Task CloseTabsAsync(bool keepClosed = false)
    {
        CancelRecovery();
        _hostKeyFailure = null;
        // A pending individual close must not create a replacement while disconnect is awaiting it.
        _share = null;
        _session = null;
        _exporting?.Cancel();
        Tabs.CanTearOutTabs = false;
        _watching?.Cancel();
        _watching = null;
        _loadingTree?.Cancel();
        _loadingTree = null;
        _filtering?.Cancel();
        _filtering = null;
        HealthBar.IsOpen = false;
        ElsewhereBar.IsOpen = false;
        HideChangesOnConnect();
        await _tabs.CloseAllAsync(keepClosed).ConfigureAwait(true);
        Tabs.TabItems.Clear();
        _snapshots.Clear();
        Objects.Clear();
        ObjectList.ItemsSource = null;
        ForgetCatalog();
        WorkspaceGrid.Visibility = Visibility.Collapsed;
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        SessionChanged?.Invoke(this, EventArgs.Empty);
    }

    // Also how SQL from elsewhere opens in an editor: a definition's text or a run from the history.
    public void NewQueryTab(string? sql = null, string? title = null) => AddQuery(sql, title ?? NextQueryTitle(), null);

    // A definition read from another database runs there; rolledBack says the app ended in the tab's transaction.
    private void AddQuery(string? sql, string title, int? index, string? database = null, bool rolledBack = false)
    {
        if (_share is null)
        {
            return;
        }

        AddTab(new QueryTabView(_workbench, _share, title, sql, database, rolledBack), Symbol.Document, index);
    }

    // The open tab of the table is brought forward rather than a second one opened.
    private TableTabView? OpenTable(ObjectEntry entry)
    {
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
        {
            if (item.Content is TableTabView view && view.Shows(entry.Schema, entry.Name))
            {
                Tabs.SelectedItem = item;
                return view;
            }
        }

        return AddTable(entry.Schema, entry.Name, entry.Kind, null, null);
    }

    private TableTabView? AddTable(string? schema, string name, ObjectKind kind, int? index, SessionTab? restore)
    {
        if (_share is null)
        {
            return null;
        }

        // Its first page is read when the tab first shows, so a restored session reads only the tab it shows.
        var table = new TableTabView(_workbench, _share, schema, name, kind, restore);
        AddTab(table, IconOf(kind), index);
        return table;
    }

    private void OpenDefinition(ObjectEntry entry)
    {
        foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
        {
            if (item.Content is DefinitionTabView view && view.Shows(entry))
            {
                Tabs.SelectedItem = item;
                return;
            }
        }

        AddDefinition(entry, null);
    }

    private void AddDefinition(ObjectEntry entry, int? index)
    {
        if (_share is null)
        {
            return;
        }

        var definition = new DefinitionTabView(_share, entry);
        AddTab(definition, IconOf(entry.Kind), index);
        definition.Load();
    }

    // A restored or reopened tab; a definition this build cannot name again stays closed.
    private void Restore(SessionTab tab, int? index)
    {
        switch (tab)
        {
            case { Kind: TabKind.Table, Table: { } table }:
                AddTable(tab.Schema, table, tab.ObjectKindOr(ObjectKind.Table), index, tab);
                break;
            case { Kind: TabKind.Definition }:
                if (DefinitionTab.EntryOf(tab) is { } entry)
                {
                    AddDefinition(entry, index);
                }

                break;
            default:
                AddQuery(tab.Sql, tab.Title, index, tab.Database, tab.HeldTransaction);
                break;
        }
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
        if (_share is null || _tabs.TakeClosed() is not { } closed)
        {
            return;
        }

        Restore(closed.Tab, Math.Min(closed.Index, Tabs.TabItems.Count));
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task ToggleHistoryAsync()
    {
        if (HistoryVisible)
        {
            HideSidePane();
            return;
        }

        await ShowHistoryAsync(focus: true).ConfigureAwait(true);
    }

    // The store opens once for the app; a pane without one says the history is unavailable.
    private async Task ShowHistoryAsync(bool focus)
    {
        if (_session is not { } session || _openingHistory)
        {
            return;
        }

        var pane = _historyPane;
        if (pane is null || _historyConnection != session.Id)
        {
            _openingHistory = true;
            QueryHistory? history;
            try
            {
                history = await _workbench.GetHistoryAsync().ConfigureAwait(true);
            }
            finally
            {
                _openingHistory = false;
            }

            if (!ReferenceEquals(_session, session))
            {
                return;
            }

            // A file opened without saving gets a new id each time it opens, so its pane lists every connection's runs.
            var connection = _connection.ConnectionId is null ? (Guid?)null : session.Id;
            pane = new HistoryPane(history is null ? null : new HistoryList(new CoreHistoryStore(history), connection))
            {
                CanSaveQuery = CanShowSavedQueries,
            };
            pane.OpenRequested += (_, sql) => NewQueryTab(sql);
            pane.SaveRequested += async (_, sql) => await SaveQueryAsync(sql).ConfigureAwait(true);
            pane.CloseRequested += (_, _) =>
            {
                HideSidePane();
                ActiveTab?.FocusContent();
            };
            _historyPane = pane;
            _historyConnection = session.Id;
        }

        ShowSidePane(pane);
        if (focus)
        {
            pane.FocusSearch();
        }

        await pane.RefreshAsync().ConfigureAwait(true);
    }

    public async Task ToggleSavedQueriesAsync()
    {
        if (SavedQueriesVisible)
        {
            HideSidePane();
            return;
        }

        await ShowSavedQueriesAsync(focus: true).ConfigureAwait(true);
    }

    // The store opens once for the app, in the history's database; a pane without one says they are unavailable.
    private async Task ShowSavedQueriesAsync(bool focus)
    {
        if (_session is not { } session || _connection.ConnectionId is not { } connectionId || _openingSaved)
        {
            return;
        }

        var pane = _savedPane;
        if (pane is null)
        {
            _openingSaved = true;
            SavedQueries? store;
            try
            {
                store = await _workbench.GetSavedQueriesAsync().ConfigureAwait(true);
            }
            finally
            {
                _openingSaved = false;
            }

            if (!ReferenceEquals(_session, session))
            {
                return;
            }

            pane = new SavedQueriesPane(store, connectionId, () => _connection.Name);
            pane.InsertRequested += (_, sql) => InsertQuery(sql);
            pane.OpenRequested += (_, sql) => NewQueryTab(sql);
            pane.CloseRequested += (_, _) =>
            {
                HideSidePane();
                ActiveTab?.FocusContent();
            };
            _savedPane = pane;
        }

        ShowSidePane(pane);
        await pane.RefreshAsync().ConfigureAwait(true);
        if (focus)
        {
            pane.FocusTree();
        }
    }

    // One pane at a time beside the tabs, so showing one puts the other away.
    private void ShowSidePane(UserControl pane)
    {
        SideHost.Child = pane;
        SideColumn.Width = new GridLength(SidePaneWidth);
        SideHost.Visibility = Visibility.Visible;
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void HideSidePane()
    {
        SideHost.Visibility = Visibility.Collapsed;
        SideColumn.Width = new GridLength(0);
        CommandsChanged?.Invoke(this, EventArgs.Empty);
    }

    // Query > Save query...: the whole tab's text.
    public async Task SaveQueryAsync()
    {
        if (CanSaveQuery && ActiveTab is QueryTabView { Editor: { } editor })
        {
            await SaveQueryAsync(editor.Document.Snapshot()).ConfigureAwait(true);
        }
    }

    private async Task SaveQueryAsync(string sql)
    {
        sql = sql.Trim();
        if (_connection.ConnectionId is not { } connectionId || sql.Length == 0)
        {
            return;
        }

        if (await _workbench.GetSavedQueriesAsync().ConfigureAwait(true) is not { } store)
        {
            var dialog = new ContentDialog
            {
                RequestedTheme = ActualTheme,
                Title = Strings.Get("SavedQueriesUnavailableTitle"),
                Content = Strings.Get("SavedQueriesUnavailableMessage"),
                CloseButtonText = Strings.Get("Close"),
                DefaultButton = ContentDialogButton.Close,
            };
            await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true);
            return;
        }

        if (await SaveQueryDialog.SaveAsync(this, store, connectionId, _connection.Name, sql).ConfigureAwait(true)
                is { } place
            && _savedPane is { } pane)
        {
            await pane.RevealAsync(place).ConfigureAwait(true);
        }
    }

    // Insert in editor: a blank query tab takes the text, one with text gets it after a blank line, else a new tab opens.
    private void InsertQuery(string sql)
    {
        var query = ActiveTab as QueryTabView;
        var editor = query?.Editor;
        var insertion = SavedQueryText.Insertion(editor?.Document.Snapshot(), sql);
        if (query is null || editor is null || insertion.Kind == SavedQueryInsertKind.NewTab)
        {
            NewQueryTab(sql);
            return;
        }

        // Through the editor's model, so Undo takes it back.
        var start = insertion.Kind == SavedQueryInsertKind.Replace ? 0 : editor.Document.Length;
        editor.Model.ReplaceRange(start, editor.Document.Length, insertion.Text);
        editor.EnsureCaretVisible();
        editor.Invalidate();
        query.FocusContent();
    }

    private static bool HasText(TextDocument document)
    {
        foreach (var chunk in document.Chunks(0, document.Length))
        {
            if (!chunk.Span.IsWhiteSpace())
            {
                return true;
            }
        }

        return false;
    }

    private async void OnHistoryRecorded(object? sender, EventArgs e)
    {
        if (HistoryVisible && _historyPane is { } pane)
        {
            await pane.RefreshAsync().ConfigureAwait(true);
        }
    }

    private void OnOpenInEditor(object? sender, ObjectSource source) =>
        AddQuery(source.Sql, NextQueryTitle(), null, source.Database);

    // The rows the tab shows: the query's result, or the table's page, or the whole table read again.
    public async Task ExportAsync()
    {
        if (!CanExport || _share is not { } share || ActiveTab is not { } tab || ResultsOf(tab) is not { } results)
        {
            return;
        }

        var table = (tab as TableTabView)?.Model.Table;
        var plan = ExportPlan.For(table, Strings.Get("ExportResultsName"));
        if (await ExportDialog.AskAsync(this, plan).ConfigureAwait(true) is not { } request
            || _exporting is not null
            || !ReferenceEquals(_share, share))
        {
            return;
        }

        // Read now, since the dialogs left the tab free to run again or page meanwhile.
        using var exporting = new CancellationTokenSource();
        Task<long> export;
        if (request.Scope == ExportScope.EntireTable && tab is TableTabView whole)
        {
            var sort = results.Sort is { Direction: not SortDirection.None } shown
                ? new ColumnSort(shown.Column, shown.Direction == SortDirection.Ascending)
                : null;
            export = share.Session.ExportTableAsync(
                whole.Model.Table, sort, whole.Model.Filter, request.Format, request.Path, exporting.Token);
        }
        else if (results.ShownSet is { } rows)
        {
            export = share.Session.ExportRowsAsync(
                rows, results.Columns.Count, request.Format, table, request.Path, exporting.Token);
        }
        else
        {
            ShowExport(InfoBarSeverity.Error, Strings.Get("ExportRowsGone"), running: false);
            return;
        }

        var name = Path.GetFileName(request.Path);
        _exporting = exporting;
        ShowExport(InfoBarSeverity.Informational, Strings.Format("ExportRunning", name), running: true);
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            var written = await export.ConfigureAwait(true);
            ShowExport(
                InfoBarSeverity.Success,
                Strings.Format(written == 1 ? "ExportDoneOne" : "ExportDoneMany", written, name),
                running: false);
        }
        catch (OperationCanceledException)
        {
            ShowExport(InfoBarSeverity.Informational, Strings.Get("ExportCancelled"), running: false);
        }
        catch (TableProException exception)
        {
            ShowExport(InfoBarSeverity.Error, Strings.Error(exception.Error), running: false);
        }
        catch (ObjectDisposedException)
        {
            // A new run or a close let go of the rows as the export began.
            ShowExport(InfoBarSeverity.Error, Strings.Get("ExportRowsGone"), running: false);
        }
        finally
        {
            _exporting = null;
            CommandsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    // One at a time with exports, so the bar and its Stop button belong to it while the rows go in.
    private async Task ImportCsvAsync(ObjectEntry entry)
    {
        if (_session is not { } session || _exporting is not null)
        {
            return;
        }

        var table = new TableName(entry.Schema, entry.Name);
        var importing = new CancellationTokenSource();
        _exporting = importing;
        CommandsChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            var result = await ImportCsvDialog.RunAsync(
                    this,
                    session,
                    table,
                    rows => ShowExport(InfoBarSeverity.Informational, Strings.Format("ImportCsvRunning", rows, entry.Name), running: true),
                    importing.Token)
                .ConfigureAwait(true);
            if (result is null)
            {
                ExportBar.IsOpen = false;
                return;
            }

            ShowExport(result.Succeeded ? InfoBarSeverity.Success : InfoBarSeverity.Error, result.Message, running: false);
            if (result.TableChanged)
            {
                foreach (var item in Tabs.TabItems.OfType<TabViewItem>())
                {
                    if (item.Content is TableTabView view && view.Shows(entry.Schema, entry.Name))
                    {
                        await view.RefreshRowsAsync().ConfigureAwait(true);
                    }
                }
            }
        }
        finally
        {
            _exporting = null;
            importing.Dispose();
            CommandsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void ShowExport(InfoBarSeverity severity, string message, bool running)
    {
        ExportBar.Severity = severity;
        ExportBar.Message = message;
        ExportBar.IsClosable = !running;
        ExportProgress.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        CancelExportButton.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        // A closed InfoBar keeps its margin, so the bar is collapsed while it is closed.
        ExportBar.Visibility = Visibility.Visible;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        ExportBar.IsOpen = false;
        ExportBar.IsOpen = true;
    }

    private void OnExportBarClosed(InfoBar sender, InfoBarClosedEventArgs args) =>
        ExportBar.Visibility = Visibility.Collapsed;

    private void OnCancelExport(object sender, RoutedEventArgs e) => _exporting?.Cancel();

    public Task ShareAsync(ShareKind kind) => ShareAsync(ActiveTab, kind);

    private async Task ShareAsync(ITabContent? tab, ShareKind kind)
    {
        if (_session is null || ShareSubjectOf(tab, kind) is not { } subject)
        {
            return;
        }

        await ShareSheet.ShowAsync(this, _workbench, subject).ConfigureAwait(true);
    }

    private async void OnShareRequested(object? sender, ShareKind kind) =>
        await ShareAsync(sender as ITabContent, kind).ConfigureAwait(true);

    // A query's text, the finished rows a query tab shows, or a table's whole view, read from its first row.
    private ShareSubject? ShareSubjectOf(ITabContent? tab, ShareKind kind)
    {
        var dialect = _session?.EngineId;
        return (tab, kind) switch
        {
            (QueryTabView query, ShareKind.Query) => query.QueryToShare is var sql && !string.IsNullOrWhiteSpace(sql)
                ? ShareSubject.Query(sql, query.Title, dialect)
                : null,
            (QueryTabView { IsRunning: false } query, ShareKind.Result)
                when query.ResultsView.ShownSet is { IsFinished: true } rows =>
                ShareSubject.Result(query.LastStatement ?? string.Empty, query.Title, dialect, rows, query.ResultsView.Columns),
            (TableTabView { IsRunning: false, HasUnsavedChanges: false } table, ShareKind.Result)
                when table.ResultsView.ShownSet is { IsFinished: true } =>
                ShareSubject.Table(table.Title, dialect, table.Model.ReadForShareAsync),
            _ => null,
        };
    }

    private static ResultsPane? ResultsOf(ITabContent? tab) => tab switch
    {
        QueryTabView query => query.ResultsView,
        TableTabView table => table.ResultsView,
        _ => null,
    };

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

        ForgetCatalog();
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
        // A tab that is not shown is out of the tree, so its questions are asked from here, as a held transaction's are.
        if (item.Content is TableTabView table)
        {
            table.DialogOwner = this;
        }

        item.ContextRequested += OnTabContextRequested;
        if (item.Content is ITabContent content)
        {
            content.StateChanged += OnTabStateChanged;
            if (content.Editor is { } editor)
            {
                editor.TextChanged += OnEditorTextChanged;
                _editorHasText[editor] = HasText(editor.Document);
            }
        }

        // A tab asks the workspace that holds it now, which a move to another window changes.
        if (item.Content is IShareSource source)
        {
            source.ShareRequested += OnShareRequested;
        }

        if (item.Content is TableTabView tableTab)
        {
            tableTab.DraftChanged += OnEditorTextChanged;
            tableTab.SessionWriteRequested += OnSessionWriteRequested;
        }

        if (item.Content is QueryTabView query)
        {
            query.HistoryRecorded += OnHistoryRecorded;
        }
        else if (item.Content is DefinitionTabView definition)
        {
            definition.OpenInEditorRequested += OnOpenInEditor;
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
                _editorHasText.Remove(editor);
            }

            _snapshots.Remove(content);
        }

        if (item.Content is IShareSource source)
        {
            source.ShareRequested -= OnShareRequested;
        }

        if (item.Content is TableTabView tableTab)
        {
            tableTab.DraftChanged -= OnEditorTextChanged;
            tableTab.SessionWriteRequested -= OnSessionWriteRequested;
        }

        if (item.Content is QueryTabView query)
        {
            query.HistoryRecorded -= OnHistoryRecorded;
        }
        else if (item.Content is DefinitionTabView definition)
        {
            definition.OpenInEditorRequested -= OnOpenInEditor;
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

    private void OnEditorTextChanged(object? sender, EventArgs e)
    {
        SessionChanged?.Invoke(this, EventArgs.Empty);
        if (sender is SqlEditor editor
            && _editorHasText.TryGetValue(editor, out var had)
            && HasText(editor.Document) is var has
            && has != had)
        {
            _editorHasText[editor] = has;
            if (ReferenceEquals(ActiveTab?.Editor, editor))
            {
                CommandsChanged?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    private void OnSessionWriteRequested(object? sender, EventArgs e) => Host?.WriteSessionNow();

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

    private Task CloseTabAsync(TabViewItem item) => _tabs.CloseAsync(item);

    IReadOnlyList<TabViewItem> IWorkspaceTabsView<TabViewItem>.Items => [.. Tabs.TabItems.OfType<TabViewItem>()];

    IWorkspaceTab? IWorkspaceTabsView<TabViewItem>.ContentOf(TabViewItem item) => item.Content as ITabContent;

    void IWorkspaceTabsView<TabViewItem>.SelectTab(TabViewItem item) => Tabs.SelectedItem = item;

    Task<bool> IWorkspaceTabsView<TabViewItem>.ConfirmCloseHeldAsync(IWorkspaceTab tab) => ConfirmCloseHeldAsync(tab);

    void IWorkspaceTabsView<TabViewItem>.Remove(TabViewItem item) => Release(item);

    private async Task<bool> ConfirmCloseHeldAsync(IWorkspaceTab content)
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

        // Each load clears the tree before it adds, so a refresh pressed again ends the load still running.
        _loadingTree?.Cancel();
        using var loading = new CancellationTokenSource();
        _loadingTree = loading;
        try
        {
            var schemas = await session.GetSchemasAsync(loading.Token).ConfigureAwait(true);
            loading.Token.ThrowIfCancellationRequested();
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
                    ? await session.RefreshObjectsAsync(ObjectScope.DefaultSchema, loading.Token).ConfigureAwait(true)
                    : await session.GetObjectsAsync(ObjectScope.DefaultSchema, loading.Token).ConfigureAwait(true);
                // The core may answer after the cancel, and its answer then is the replaced load's.
                loading.Token.ThrowIfCancellationRequested();
                var folders = await GroupAsync(objects).ConfigureAwait(true);
                loading.Token.ThrowIfCancellationRequested();
                AddFolders(Objects, shown.FirstOrDefault()?.Name, folders);
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
        catch (Exception exception) when (loading.IsCancellationRequested
            && exception is OperationCanceledException or TableProException)
        {
            // A newer load, or the session closing, took over the tree.
        }
        catch (TableProException exception)
        {
            ShowListMessage(Strings.Error(exception.Error));
        }
        finally
        {
            if (ReferenceEquals(_loadingTree, loading))
            {
                _loadingTree = null;
            }
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
        var folders = await GroupAsync(objects).ConfigureAwait(true);
        node.Children.Clear();
        AddFolders(node.Children, node.Schema, folders);
    }

    // A schema can hold tens of thousands of objects, and a culture-aware sort of them would stall the UI thread.
    private static Task<IReadOnlyList<ObjectFolder>> GroupAsync(IReadOnlyList<ObjectEntry> objects)
    {
        var culture = CultureInfo.CurrentCulture;
        return Task.Run(() => ObjectFolders.Group(objects, culture));
    }

    private static void AddFolders(ObservableCollection<ObjectNode> target, string? schema, IReadOnlyList<ObjectFolder> folders)
    {
        foreach (var folder in folders)
        {
            target.Add(new ObjectNode(ObjectNodeKind.Folder, Strings.Get("Folder_" + folder.Kind))
            {
                Icon = Symbol.Folder,
                Detail = folder.Objects.Count.ToString(CultureInfo.CurrentCulture),
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
            Icon = IconOf(entry.Kind),
        };

    // The tree's row and the object's tab show the same symbol.
    private static Symbol IconOf(ObjectKind kind) => kind switch
    {
        ObjectKind.View or ObjectKind.MaterializedView => Symbol.View,
        ObjectKind.Sequence => Symbol.Sort,
        ObjectKind.Function or ObjectKind.Procedure => Symbol.Calculator,
        ObjectKind.Trigger => Symbol.Flag,
        ObjectKind.Key => Symbol.Tag,
        _ => Symbol.ViewAll,
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

    // Rows open a table tab, code a definition tab; a key or an unknown kind has nothing to open.
    private void Open(ObjectNode node)
    {
        if (node.Entry is not { } entry)
        {
            return;
        }

        if (ObjectFolders.HasRows(entry.Kind))
        {
            OpenTable(entry);
        }
        else if (ObjectFolders.HasDefinition(entry.Kind))
        {
            OpenDefinition(entry);
        }
    }

    private void OnObjectRowContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (sender is TreeViewItem row && ObjectTree.ItemFromContainer(row) is ObjectNode { Entry: { } entry })
        {
            args.Handled = true;
            ShowObjectMenu(row, entry, args);
        }
    }

    // A key asks from the focused row, which is the list item around the template, so the list takes the event.
    private void OnObjectListContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (ListItemAt(args.OriginalSource) is { } row
            && ObjectList.ItemFromContainer(row) is ObjectNode { Entry: { } entry })
        {
            args.Handled = true;
            ShowObjectMenu(row, entry, args);
        }
    }

    private static ListViewItem? ListItemAt(object? source)
    {
        var element = source as DependencyObject;
        while (element is not null and not ListViewItem)
        {
            element = VisualTreeHelper.GetParent(element);
        }

        return element as ListViewItem;
    }

    // Built when asked for, as the tab menu is, with the macOS sidebar's commands for the object's kind.
    private void ShowObjectMenu(FrameworkElement row, ObjectEntry entry, ContextRequestedEventArgs args)
    {
        var menu = new MenuFlyout();
        if (ObjectFolders.HasRows(entry.Kind))
        {
            menu.Items.Add(ObjectMenuItem("ObjectMenuOpen", Symbol.OpenFile, () => OpenTable(entry)));
            menu.Items.Add(ObjectMenuItem(
                "ObjectMenuShowStructure", Symbol.List, () => OpenTable(entry)?.ShowStructure()));
            if (entry.Kind is ObjectKind.Table or ObjectKind.PartitionedTable)
            {
                menu.Items.Add(ObjectMenuItem("ObjectMenuImportCsv", Symbol.Import, async () => await ImportCsvAsync(entry).ConfigureAwait(true)));
            }

            menu.Items.Add(new MenuFlyoutSeparator());
        }
        else if (ObjectFolders.HasDefinition(entry.Kind))
        {
            menu.Items.Add(ObjectMenuItem("ObjectMenuShowDdl", Symbol.Preview, () => OpenDefinition(entry)));
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        menu.Items.Add(ObjectMenuItem("ObjectMenuCopyName", Symbol.Copy, () => CopyText(entry.Name)));
        if (args.TryGetPosition(row, out var point))
        {
            menu.ShowAt(row, new FlyoutShowOptions { Position = point });
        }
        else
        {
            menu.ShowAt(row);
        }
    }

    private static MenuFlyoutItem ObjectMenuItem(string text, Symbol icon, Action invoke)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text), Icon = new SymbolIcon(icon) };
        item.Click += (_, _) => invoke();
        return item;
    }

    internal static void CopyText(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (COMException)
        {
            // Another program holds the clipboard open; copying again works once it lets go.
        }
    }

    // Each keystroke scans the catalog on the thread pool and stops the scan it replaces.
    private async void OnFilterChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        var text = sender.Text;
        var generation = ++_filterGeneration;
        _filtering?.Cancel();
        _filtering = null;
        if (string.IsNullOrWhiteSpace(text))
        {
            ShowTree();
            return;
        }

        if (_session is not { } session)
        {
            return;
        }

        using var filtering = new CancellationTokenSource();
        _filtering = filtering;
        try
        {
            var catalog = _everyObject;
            while (catalog is null)
            {
                var reading = _catalogGeneration;
                var objects = await session
                    .GetObjectsAsync(_singleSchema ? ObjectScope.DefaultSchema : ObjectScope.AllSchemas)
                    .ConfigureAwait(true);
                var culture = CultureInfo.CurrentCulture;
                var read = await Task.Run(() => new ObjectCatalog(objects, culture)).ConfigureAwait(true);
                if (filtering.IsCancellationRequested || !ReferenceEquals(_session, session))
                {
                    return;
                }

                // A refresh during the read dropped the catalog, so the one it reads now is the one to keep.
                if (reading == _catalogGeneration)
                {
                    catalog = _everyObject ??= read;
                }
            }

            // Typing on while the catalog loads leaves only the newest text to show.
            if (generation != _filterGeneration)
            {
                return;
            }

            var showSchema = !_singleSchema;
            var token = filtering.Token;
            var nodes = await Task.Run(
                    () => catalog.Filter(text, token).Select(entry => EntryNode(entry, showSchema)).ToList(),
                    token)
                .ConfigureAwait(true);
            if (generation != _filterGeneration || token.IsCancellationRequested)
            {
                return;
            }

            ShowList(nodes, Strings.Format("FilterMatches", nodes.Count));
        }
        catch (OperationCanceledException) when (filtering.IsCancellationRequested)
        {
            // A newer keystroke took over the list.
        }
        catch (TableProException exception)
        {
            ShowListMessage(Strings.Error(exception.Error));
        }
        finally
        {
            if (ReferenceEquals(_filtering, filtering))
            {
                _filtering = null;
            }
        }
    }

    private void ForgetCatalog()
    {
        _everyObject = null;
        _catalogGeneration++;
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

    private void OnCopyDetails(object sender, RoutedEventArgs e) => CopyText(_failureDetails);
}
