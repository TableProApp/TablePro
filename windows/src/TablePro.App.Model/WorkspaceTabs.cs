using TablePro.Interop;

namespace TablePro.App.Model;

// What a workspace and its window read of a tab before they close it.
public interface IWorkspaceTab
{
    string Title { get; }

    TabKind Kind { get; }

    bool IsRunning { get; }

    // The transaction the tab's own connection holds; the workspace names a held one over the other tabs.
    TransactionState Transaction { get; }

    bool HasUnsavedChanges { get; }

    // Asks about unsaved changes before a close and may save them, unless offerSave is off; false keeps the tab.
    Task<bool> ConfirmCloseAsync(bool offerSave);

    SessionTab Snapshot();

    // For the session's own writes alone: what an end without a close would lose, which a relaunch brings back.
    SessionTab WithPendingWork(SessionTab snapshot);

    // Once only, however often it is asked for: the tab lets go of its session exactly once.
    Task CloseAsync();
}

// The tab strip in its order. TItem is the strip's own item, which can move to another window's strip.
public interface IWorkspaceTabsView<TItem>
{
    IReadOnlyList<TItem> Items { get; }

    IWorkspaceTab? ContentOf(TItem item);

    void SelectTab(TItem item);

    // Closing a tab ends its own connection, and its transaction with it.
    Task<bool> ConfirmCloseHeldAsync(IWorkspaceTab tab);

    // The workspace lets go of the item; its content is closed or moves to another strip.
    void Remove(TItem item);
}

public sealed class WorkspaceTabs<TItem>
    where TItem : class
{
    private readonly IWorkspaceTabsView<TItem> _view;
    private readonly ClosedTabs _closed = new();
    private readonly HashSet<TItem> _closing = [];

    public WorkspaceTabs(IWorkspaceTabsView<TItem> view)
    {
        ArgumentNullException.ThrowIfNull(view);
        _view = view;
    }

    // The user closed the last tab; a window a tab was moved into closes with it.
    public event EventHandler? Emptied;

    public int ClosedCount => _closed.Count;

    // A second request while the first is closing the tab, or asking about its transaction, does nothing.
    public async Task CloseAsync(TItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (!_closing.Add(item))
        {
            return;
        }

        try
        {
            if (_view.ContentOf(item) is { } content)
            {
                if (WorkspaceNotices.Holds(content.Transaction)
                    && !await _view.ConfirmCloseHeldAsync(content).ConfigureAwait(true))
                {
                    return;
                }

                // The question names the tab, so it shows first.
                if (content.HasUnsavedChanges)
                {
                    _view.SelectTab(item);
                    if (!await content.ConfirmCloseAsync(offerSave: true).ConfigureAwait(true))
                    {
                        return;
                    }
                }

                _closed.Push(content.Snapshot(), IndexOf(item));
                await content.CloseAsync().ConfigureAwait(true);
            }
        }
        finally
        {
            _closing.Remove(item);
        }

        _view.Remove(item);
        if (_view.Items.Count == 0)
        {
            Emptied?.Invoke(this, EventArgs.Empty);
        }
    }

    // A held transaction or unsaved changes not answered for yet.
    public bool HasUnconfirmed(ISet<IWorkspaceTab> confirmed)
    {
        ArgumentNullException.ThrowIfNull(confirmed);
        return _view.Items.Any(item => _view.ContentOf(item) is { } content && Asks(content, confirmed));
    }

    public PendingWork Pending()
    {
        var tabs = _view.Items.Select(_view.ContentOf).OfType<IWorkspaceTab>().ToList();
        return new PendingWork(
            tabs.Any(tab => tab.HasUnsavedChanges),
            tabs.Any(tab => WorkspaceNotices.Holds(tab.Transaction)));
    }

    // Each tab shows before its question, since the question names it.
    public async Task<bool> ConfirmCloseAsync(ISet<IWorkspaceTab> confirmed, bool offerSave = true)
    {
        ArgumentNullException.ThrowIfNull(confirmed);
        foreach (var item in _view.Items.ToList())
        {
            if (_view.ContentOf(item) is not { } content || !Asks(content, confirmed))
            {
                continue;
            }

            _view.SelectTab(item);
            if (WorkspaceNotices.Holds(content.Transaction)
                && !await _view.ConfirmCloseHeldAsync(content).ConfigureAwait(true))
            {
                return false;
            }

            if (content.HasUnsavedChanges && !await content.ConfirmCloseAsync(offerSave).ConfigureAwait(true))
            {
                return false;
            }

            confirmed.Add(content);
        }

        return true;
    }

    // A table tab loading a page is not work the user started, so only a query tab's run is asked about.
    public IReadOnlyList<IWorkspaceTab> RunningQueries() =>
    [
        .. _view.Items
            .Select(_view.ContentOf)
            .OfType<IWorkspaceTab>()
            .Where(tab => tab is { Kind: TabKind.Query, IsRunning: true }),
    ];

    // The tabs of a window that closed, so Reopen closed tab brings them back here in their order.
    public void KeepClosed(IReadOnlyList<SessionTab> tabs)
    {
        ArgumentNullException.ThrowIfNull(tabs);
        for (var index = tabs.Count - 1; index >= 0; index--)
        {
            _closed.Push(tabs[index], int.MaxValue);
        }
    }

    public ClosedTab? TakeClosed() => _closed.Pop();

    // A reconnect keeps the closed tabs, which hold only their text or table, to reopen on the next session.
    public async Task CloseAllAsync(bool keepClosed)
    {
        if (!keepClosed)
        {
            _closed.Clear();
        }

        foreach (var tab in _view.Items.Select(_view.ContentOf).OfType<IWorkspaceTab>().ToList())
        {
            await tab.CloseAsync().ConfigureAwait(true);
        }
    }

    private static bool Asks(IWorkspaceTab tab, ISet<IWorkspaceTab> confirmed) =>
        (WorkspaceNotices.Holds(tab.Transaction) || tab.HasUnsavedChanges) && !confirmed.Contains(tab);

    private int IndexOf(TItem item)
    {
        var items = _view.Items;
        for (var index = 0; index < items.Count; index++)
        {
            if (ReferenceEquals(items[index], item))
            {
                return index;
            }
        }

        return -1;
    }
}
