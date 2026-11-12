using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class WorkspaceTabsTests
{
    private readonly FakeStrip _strip = new();
    private readonly WorkspaceTabs<FakeTab> _tabs;

    public WorkspaceTabsTests()
    {
        _tabs = new WorkspaceTabs<FakeTab>(_strip);
    }

    [Fact]
    public async Task ATabHoldingATransactionAsksFirstAndStaysWhenTheAnswerIsNo()
    {
        var held = new FakeTab("Query 1") { Transaction = TransactionState.InTransaction };
        _strip.Tabs.Add(held);
        _strip.Answer = _ => false;

        await _tabs.CloseAsync(held);

        Assert.Equal<string>(["Query 1"], _strip.Asked);
        Assert.Equal(0, held.Closes);
        Assert.Single(_strip.Tabs);
        Assert.Equal(0, _tabs.ClosedCount);
    }

    [Fact]
    public async Task AClosedTabIsKeptAtItsPlaceToReopenAndTheLastOneEmptiesTheStrip()
    {
        var first = new FakeTab("Query 1");
        var second = new FakeTab("Artist", TabKind.Table) { Transaction = TransactionState.Failed };
        _strip.Tabs.AddRange([first, second]);
        var emptied = 0;
        _tabs.Emptied += (_, _) => emptied++;

        await _tabs.CloseAsync(second);

        Assert.Equal(1, second.Closes);
        Assert.Equal<string>(["Artist"], _strip.Asked);
        Assert.Equal(0, emptied);

        await _tabs.CloseAsync(first);

        Assert.Empty(_strip.Tabs);
        Assert.Equal(1, emptied);
        Assert.Equal(new ClosedTab(first.Snapshot(), 0), _tabs.TakeClosed());
        Assert.Equal(new ClosedTab(second.Snapshot(), 1), _tabs.TakeClosed());
        Assert.Null(_tabs.TakeClosed());
    }

    [Fact]
    public async Task ASecondCloseWhileTheFirstIsClosingTheTabDoesNothing()
    {
        var closing = new Gate();
        var tab = new FakeTab("Query 1") { Closing = closing };
        _strip.Tabs.Add(tab);

        var first = _tabs.CloseAsync(tab);
        await _tabs.CloseAsync(tab);
        var waited = !first.IsCompleted;
        closing.Open();
        await first;

        Assert.True(waited);
        Assert.Equal(1, tab.Closes);
        Assert.Empty(_strip.Tabs);
        Assert.Equal(1, _tabs.ClosedCount);
    }

    [Fact]
    public async Task ConfirmingAWindowsCloseShowsEachHeldTabAndStopsAtTheFirstNo()
    {
        var idle = new FakeTab("Query 1");
        var held = new FakeTab("Query 2") { Transaction = TransactionState.InTransaction };
        var failed = new FakeTab("Query 3") { Transaction = TransactionState.Failed };
        _strip.Tabs.AddRange([idle, held, failed]);
        _strip.Answer = tab => ReferenceEquals(tab, held);
        var confirmed = new HashSet<IWorkspaceTab>();

        Assert.True(_tabs.HasUnconfirmed(confirmed));
        Assert.False(await _tabs.ConfirmCloseAsync(confirmed));

        Assert.Equal<FakeTab>([held, failed], _strip.Selected);
        Assert.Same(held, Assert.Single(confirmed));

        _strip.Answer = _ => true;

        Assert.True(await _tabs.ConfirmCloseAsync(confirmed));
        Assert.False(_tabs.HasUnconfirmed(confirmed));
        Assert.Equal(0, idle.Closes);
    }

    [Fact]
    public async Task ATabWithUnsavedChangesShowsAndAsksBeforeItClosesAndStaysOnANo()
    {
        var other = new FakeTab("Query 1");
        var edited = new FakeTab("Artist", TabKind.Table) { HasUnsavedChanges = true, ClosesUnsaved = false };
        _strip.Tabs.AddRange([other, edited]);

        await _tabs.CloseAsync(edited);

        Assert.Same(edited, Assert.Single(_strip.Selected));
        Assert.Equal(1, edited.CloseQuestions);
        Assert.Equal(0, edited.Closes);
        Assert.Equal(2, _strip.Tabs.Count);
        Assert.Empty(_strip.Asked);

        edited.ClosesUnsaved = true;
        await _tabs.CloseAsync(edited);

        Assert.Equal(1, edited.Closes);
        Assert.Same(other, Assert.Single(_strip.Tabs));
    }

    [Fact]
    public async Task ConfirmingAWindowsCloseAsksAboutUnsavedChangesTooAndAnsweredTabsAreNotAskedAgain()
    {
        var edited = new FakeTab("Artist", TabKind.Table) { HasUnsavedChanges = true };
        var held = new FakeTab("Query 1") { Transaction = TransactionState.InTransaction };
        _strip.Tabs.AddRange([edited, held]);
        var confirmed = new HashSet<IWorkspaceTab>();

        Assert.True(_tabs.HasUnconfirmed(confirmed));
        Assert.True(await _tabs.ConfirmCloseAsync(confirmed));

        Assert.Equal<FakeTab>([edited, held], _strip.Selected);
        Assert.Equal(1, edited.CloseQuestions);
        Assert.Equal<string>(["Query 1"], _strip.Asked);
        Assert.False(_tabs.HasUnconfirmed(confirmed));

        edited.ClosesUnsaved = false;
        Assert.True(await _tabs.ConfirmCloseAsync(confirmed));
        Assert.Equal(1, edited.CloseQuestions);
    }

    [Fact]
    public void ASignOutWaitsOnUnsavedChangesAndHeldTransactionsAlone()
    {
        var running = new FakeTab("Query 1") { IsRunning = true };
        _strip.Tabs.Add(running);

        Assert.Equal(PendingWork.None, _tabs.Pending());

        var edited = new FakeTab("Artist", TabKind.Table) { HasUnsavedChanges = true };
        _strip.Tabs.Add(edited);

        Assert.Equal(new PendingWork(UnsavedChanges: true, HeldTransaction: false), _tabs.Pending());

        _strip.Tabs.Add(new FakeTab("Query 2") { Transaction = TransactionState.Failed });

        Assert.Equal(new PendingWork(UnsavedChanges: true, HeldTransaction: true), _tabs.Pending());
    }

    [Fact]
    public void EveryWorkspacesPendingWorkAddsUp()
    {
        var edits = new PendingWork(UnsavedChanges: true, HeldTransaction: false);
        var transaction = new PendingWork(UnsavedChanges: false, HeldTransaction: true);

        Assert.Equal(edits, PendingWork.None.Combine(edits).Combine(PendingWork.None));
        Assert.Equal(new PendingWork(UnsavedChanges: true, HeldTransaction: true), edits.Combine(transaction));
    }

    [Fact]
    public async Task MakingTheConnectionReadOnlyAsksWithoutSaveAndAClosedTabAsksWithIt()
    {
        var edited = new FakeTab("Artist", TabKind.Table) { HasUnsavedChanges = true };
        _strip.Tabs.Add(edited);

        Assert.True(await _tabs.ConfirmCloseAsync(new HashSet<IWorkspaceTab>(), offerSave: false));
        Assert.False(edited.OfferedSave);

        await _tabs.CloseAsync(edited);
        Assert.True(edited.OfferedSave);
    }

    [Fact]
    public async Task AFailedSaveBeforeAWindowsCloseKeepsEveryTab()
    {
        var edited = new FakeTab("Artist", TabKind.Table) { HasUnsavedChanges = true, ClosesUnsaved = false };
        var held = new FakeTab("Query 1") { Transaction = TransactionState.InTransaction };
        _strip.Tabs.AddRange([edited, held]);

        Assert.False(await _tabs.ConfirmCloseAsync(new HashSet<IWorkspaceTab>()));

        Assert.Empty(_strip.Asked);
        Assert.Equal(0, edited.Closes);
    }

    [Fact]
    public void OnlyARunningQueryTabIsAskedAboutBeforeAClose()
    {
        var running = new FakeTab("Query 1") { IsRunning = true };
        var loading = new FakeTab("Artist", TabKind.Table) { IsRunning = true };
        _strip.Tabs.AddRange([running, loading, new FakeTab("Query 2")]);

        Assert.Same(running, Assert.Single(_tabs.RunningQueries()));
    }

    [Fact]
    public async Task AClosedWindowsTabsReopenInTheirOrderAndOnlyADisconnectForgetsThem()
    {
        _tabs.KeepClosed([new SessionTab { Title = "Query 1" }, new SessionTab { Title = "Query 2" }]);

        Assert.Equal("Query 1", _tabs.TakeClosed()?.Tab.Title);

        var open = new FakeTab("Query 3");
        _strip.Tabs.Add(open);
        await _tabs.CloseAllAsync(keepClosed: true);

        Assert.Equal(1, open.Closes);
        Assert.Equal(1, _tabs.ClosedCount);

        await _tabs.CloseAllAsync(keepClosed: false);

        Assert.Equal(0, _tabs.ClosedCount);
    }
}

internal sealed class FakeTab(string title, TabKind kind = TabKind.Query) : IWorkspaceTab
{
    public string Title { get; } = title;

    public TabKind Kind { get; } = kind;

    public bool IsRunning { get; set; }

    public TransactionState Transaction { get; set; }

    public bool HasUnsavedChanges { get; set; }

    // The answer its own question gives: Save that saved, or Don't save, against Cancel or a failed save.
    public bool ClosesUnsaved { get; set; } = true;

    public Gate? Closing { get; set; }

    public int Closes { get; private set; }

    public int CloseQuestions { get; private set; }

    public bool? OfferedSave { get; private set; }

    public Task<bool> ConfirmCloseAsync(bool offerSave)
    {
        CloseQuestions++;
        OfferedSave = offerSave;
        return Task.FromResult(ClosesUnsaved);
    }

    public SessionTab Snapshot() => new() { Kind = Kind, Title = Title };

    public async Task CloseAsync()
    {
        Closes++;
        if (Closing is { } closing)
        {
            await closing.PassAsync(CancellationToken.None);
        }
    }
}

internal sealed class FakeStrip : IWorkspaceTabsView<FakeTab>
{
    public List<FakeTab> Tabs { get; } = [];

    public List<FakeTab> Selected { get; } = [];

    public List<string> Asked { get; } = [];

    public Func<IWorkspaceTab, bool> Answer { get; set; } = _ => true;

    public IReadOnlyList<FakeTab> Items => [.. Tabs];

    public IWorkspaceTab? ContentOf(FakeTab item) => item;

    public void SelectTab(FakeTab item) => Selected.Add(item);

    public Task<bool> ConfirmCloseHeldAsync(IWorkspaceTab tab)
    {
        Asked.Add(tab.Title);
        return Task.FromResult(Answer(tab));
    }

    public void Remove(FakeTab item) => Tabs.Remove(item);
}
