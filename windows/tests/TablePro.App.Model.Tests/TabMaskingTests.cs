using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

// Reveal, masked cells and a saved rule's remask, in the table and query tabs.
public sealed class TabMaskingTests
{
    private static readonly ResultColumn[] MaskedName =
    [
        new("ArtistId", "INTEGER", ValueKind.Integer),
        new("Name", "TEXT", ValueKind.Text) { Masked = MaskStyle.Full },
    ];

    private readonly FakeSession _session = new() { TableRows = 3 };
    private readonly FakeTableView _tableView = new();
    private readonly FakeQueryView _queryView = new();
    private readonly FakeResults _results = new();

    private TableTab Table()
    {
        var tab = new TableTab(
            _session, _tableView, _results, new TableName(null, "Artist"), ObjectKind.Table, () => new AppSettings());
        _tableView.Tab = tab;
        return tab;
    }

    private QueryTab Query() =>
        new("Query 1", _session, _queryView, _results, DataModel.Relational, () => new AppSettings());

    [Fact]
    public async Task AMaskedCellRefusesAnEditWhileANewRowTakesWhatIsTyped()
    {
        _session.PageColumns = MaskedName;
        var tab = Table();
        await tab.RunAsync();

        Assert.True(tab.IsColumnMasked(1));
        Assert.False(tab.IsColumnMasked(0));
        Assert.IsType<EditRefusal.MaskedCell>(tab.StartEdit(0, 1, out _));
        Assert.IsType<EditRefusal.MaskedCell>(tab.CommitEdit(0, 1, "Accept"));
        Assert.False(tab.CanSetValue(0, 1, CellValueKind.Null));
        Assert.Null(tab.AddRow(out var added));
        Assert.Null(tab.CommitEdit(added, 1, "Accept"));
    }

    [Fact]
    public async Task ARevealAsksFirstThenReadsThePageAgainWithTheStoredValues()
    {
        _session.PageColumns = MaskedName;
        var tab = Table();
        await tab.RunAsync();

        Assert.True(tab.OffersReveal);
        await tab.RevealMaskedAsync();

        Assert.Equal(1, _tableView.RevealsAsked);
        Assert.True(tab.RevealsMasked);
        Assert.False(tab.OffersReveal);
        Assert.Equal([false, true], _session.PageReveals);
        await tab.NextPageAsync();
        Assert.Equal(1, _tableView.RevealsAsked);
    }

    [Fact]
    public async Task ADeclinedRevealOrADeclinedDiscardKeepsThePageMasked()
    {
        _session.PageColumns = MaskedName;
        var tab = Table();
        await tab.RunAsync();
        _tableView.Reveals = false;

        await tab.RevealMaskedAsync();

        Assert.False(tab.RevealsMasked);
        Assert.Equal([false], _session.PageReveals);

        _tableView.Reveals = true;
        Assert.Null(tab.AddRow(out _));
        _tableView.DiscardsForReload = false;
        await tab.RevealMaskedAsync();

        Assert.Equal([ReloadReason.Reveal], _tableView.ReloadsAsked);
        Assert.False(tab.RevealsMasked);
        Assert.True(tab.HasUnsavedChanges);
        Assert.Equal([false], _session.PageReveals);
    }

    [Fact]
    public async Task APageWithNothingMaskedOffersNoRevealAndAShareNeverReadsRevealed()
    {
        var tab = Table();
        await tab.RunAsync();

        Assert.False(tab.OffersReveal);
        await tab.RevealMaskedAsync();
        Assert.Equal(0, _tableView.RevealsAsked);

        _session.PageColumns = MaskedName;
        await tab.RunAsync();
        await tab.RevealMaskedAsync();
        using var share = await tab.ReadForShareAsync(1_000, TestContext.Current.CancellationToken);

        Assert.Equal([false, false, true, false], _session.PageReveals);
    }

    [Fact]
    public async Task ASavedRuleRemasksTheRowsShownAndReadsTheirLockAgain()
    {
        var tab = Table();
        await tab.RunAsync();
        _results.Remasks = MaskedName;
        _session.TableEditor.PageLock = EditLock.MaskedKey;

        await tab.RemaskAsync();

        Assert.Equal(1, _results.RemaskCalls);
        Assert.True(tab.IsColumnMasked(1));
        Assert.Equal(EditLock.MaskedKey, tab.Lock);
        Assert.IsType<EditRefusal.TableLocked>(tab.StartEdit(0, 0, out _));
    }

    [Fact]
    public async Task ARevealedQueryTabRunsAReadAgainWithTheStoredValues()
    {
        _session.Script = _ => FakeRun.Rows(2, columns: MaskedName);
        var tab = Query();
        await tab.RunAsync();

        await tab.RevealMaskedAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Equal(["select * from Artist", "select * from Artist"], editor.Runs);
        Assert.Equal([false, true], editor.Options.Select(options => options.RevealMasked));
        Assert.Equal(["select * from Artist"], _session.ReadsOnlyAsked);
        Assert.True(tab.RevealsMasked);
        Assert.Contains("reveal asked", _queryView.Shown);
    }

    [Fact]
    public async Task AStatementThatWritesIsNotRunAgainAndTheNextRunShowsTheValues()
    {
        _session.Script = _ => FakeRun.Rows(2, columns: MaskedName);
        _session.StatementReadsOnly = false;
        var tab = Query();
        await tab.RunAsync();

        await tab.RevealMaskedAsync();
        await tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Equal([false, true], editor.Options.Select(options => options.RevealMasked));
        Assert.Contains("reveal on next run", _queryView.Shown);
    }

    [Fact]
    public async Task ADeclinedRevealLeavesTheQueryTabMasked()
    {
        _session.Script = _ => FakeRun.Rows(2, columns: MaskedName);
        _queryView.Reveals = false;
        var tab = Query();
        await tab.RunAsync();

        await tab.RevealMaskedAsync();

        Assert.False(tab.RevealsMasked);
        Assert.Single(Assert.Single(_session.Editors).Runs);
        Assert.Empty(_session.ReadsOnlyAsked);
    }

    [Fact]
    public async Task ARemaskTakesTheColumnsOfEachSetThatChangedAndSaysWhetherAnyDid()
    {
        var text = new ResultColumn("a", "", ValueKind.Text);
        var first = new RunResult(0, [text]);
        var second = new RunResult(1, [text]);
        var asked = new List<int>();

        var changed = await ResultRemask.ApplyAsync(
            [first, second],
            result =>
            {
                asked.Add(result.SetIndex);
                IReadOnlyList<ResultColumn>? read = result.SetIndex == 1 ? [text with { Masked = MaskStyle.Full }] : null;
                return Task.FromResult(read);
            });
        var none = await ResultRemask.ApplyAsync([first], _ => Task.FromResult<IReadOnlyList<ResultColumn>?>(null));

        Assert.True(changed);
        Assert.False(none);
        Assert.Equal([0, 1], asked);
        Assert.Null(Assert.Single(first.Columns).Masked);
        Assert.Equal(MaskStyle.Full, Assert.Single(second.Columns).Masked);
    }

    [Fact]
    public void ARemaskedResultTakesTheColumnsItShows()
    {
        var result = new RunResult(0, [new ResultColumn("a", "", ValueKind.Text)]);

        result.Remasked([new ResultColumn("a", "", ValueKind.Text) { Masked = MaskStyle.Hash }, new ResultColumn("rowid", "", ValueKind.Integer)]);

        var column = Assert.Single(result.Columns);
        Assert.Equal(MaskStyle.Hash, column.Masked);
    }
}
