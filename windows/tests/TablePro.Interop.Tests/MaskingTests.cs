namespace TablePro.Interop.Tests;

// A saved SQLite connection's masking rules, as the core applies them (core ADR 0026).
public sealed class MaskingTests : IAsyncLifetime
{
    private const string Bullets = "••••";
    private const string People = "SELECT id, name, note FROM people ORDER BY id";
    private static readonly TableName PeopleTable = new(null, "people");

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-masking-").FullName;
    private readonly TableProCore _core;
    private SqliteDatabase? _database;

    public MaskingTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", _directory), new MemorySecretStore());
    }

    private SqliteDatabase Database => _database ?? throw new InvalidOperationException("Not set up.");

    public async ValueTask InitializeAsync() => _database = await SqliteDatabase.CreateAsync();

    public async ValueTask DisposeAsync()
    {
        if (_database is not null)
        {
            await _database.DisposeAsync();
        }

        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private static MaskingRule Rule(string pattern, MaskStyle style, MaskTarget target = MaskTarget.Column) =>
        new(null, pattern, target, style);

    private Task<SavedConnection> SaveAsync(params MaskingRule[] rules) =>
        _core.Library.SaveAsync(
            new SavedConnection(null, "app", "sqlite", string.Empty, 0, Database.Path, string.Empty, TlsSettings.Disabled)
            {
                MaskingRules = rules,
            },
            ConnectionSecrets.None);

    private async Task<DatabaseSession> ConnectAsync(SavedConnection saved) =>
        await _core.ConnectAsync(saved.Id!.Value, cancellationToken: TestContext.Current.CancellationToken);

    private static async Task<ResultSet> RunAsync(QueryEditor editor, string sql, bool reveal = false)
    {
        using var run = editor.Run(sql, new QueryOptions { RevealMasked = reveal }, TestContext.Current.CancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        return run.GetResultSet(0) ?? throw new InvalidOperationException("The run held no set.");
    }

    private static List<string?> Column(ResultSet set, int column) =>
        [.. Enumerable.Range(0, (int)set.RowCount).Select(row => set.GetCellText(row, column))];

    [Fact]
    public async Task ASaveKeepsTheRulesInOrderWithTheirIdsAndDropsABlankPattern()
    {
        var known = Guid.NewGuid();

        var saved = await SaveAsync(
            new MaskingRule(known, "*.email", MaskTarget.Column, MaskStyle.Email),
            Rule("uuid", MaskStyle.Hash, MaskTarget.Type),
            Rule("  ", MaskStyle.Full));
        var stored = Assert.Single((await _core.Library.GetSnapshotAsync()).Connections);

        Assert.Equal(saved.MaskingRules, stored.MaskingRules);
        Assert.Equal(2, stored.MaskingRules.Count);
        Assert.Equal(new MaskingRule(known, "*.email", MaskTarget.Column, MaskStyle.Email), stored.MaskingRules[0]);
        Assert.Equal(("uuid", MaskTarget.Type, MaskStyle.Hash), (stored.MaskingRules[1].Pattern, stored.MaskingRules[1].Target, stored.MaskingRules[1].Style));
        Assert.NotNull(stored.MaskingRules[1].Id);
    }

    [Fact]
    public async Task TheGridShowsMaskedValuesUnlessTheTabRevealedThem()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(await SaveAsync(Rule("name", MaskStyle.Full)));
        await using var editor = await session.OpenEditorAsync(cancellationToken);

        using var shown = await RunAsync(editor, People);
        using var revealed = await RunAsync(editor, People, reveal: true);
        var page = await session.ReadTablePageAsync(PeopleTable, null, null, 100, cancellationToken: cancellationToken);
        using var pageRun = page.Run;
        Assert.IsType<QueryOutcome.Completed>(await pageRun.Completion);
        using var pageRows = pageRun.GetResultSet(0)!;
        var open = await session.ReadTablePageAsync(PeopleTable, null, null, 100, revealMasked: true, cancellationToken: cancellationToken);
        using var openRun = open.Run;
        Assert.IsType<QueryOutcome.Completed>(await openRun.Completion);
        using var openRows = openRun.GetResultSet(0)!;

        Assert.Equal([null, MaskStyle.Full, null], shown.GetColumns().Select(column => column.Masked));
        Assert.Equal([Bullets, Bullets, Bullets], Column(shown, 1));
        Assert.Equal(["Ada", "Grace", "Zoë 👋"], Column(revealed, 1));
        Assert.All(revealed.GetColumns(), column => Assert.Null(column.Masked));
        Assert.Equal(MaskStyle.Full, pageRows.GetColumns()[1].Masked);
        Assert.Equal([Bullets, Bullets, Bullets], Column(pageRows, 1));
        Assert.Equal(["Ada", "Grace", "Zoë 👋"], Column(openRows, 1));
    }

    [Fact]
    public async Task AMaskedCellRefusesAnEditAndAMaskedKeyLocksThePage()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(await SaveAsync(Rule("name", MaskStyle.LastFour)));
        using var editor = await session.OpenTableEditorAsync(PeopleTable, false, cancellationToken);
        var page = await session.ReadTablePageAsync(PeopleTable, null, null, 100, cancellationToken: cancellationToken);
        using var run = page.Run;
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var rows = run.GetResultSet(0)!;

        var start = editor.GetEditStart(rows, 0, 1);
        var refused = Assert.Throws<TableProException>(
            () => editor.Plan(rows, [new RowEdit.Update(0, [new CellChange(1, new CellEdit.Text("Ann"))])]));

        Assert.IsType<EditStart.Locked>(start);
        Assert.Equal("edit.masked_column", refused.Code);
        Assert.Null(editor.LockFor(rows));

        await using var keyed = await ConnectAsync(await SaveAsync(Rule("id", MaskStyle.Hash)));
        using var keyedEditor = await keyed.OpenTableEditorAsync(PeopleTable, false, cancellationToken);
        var keyedPage = await keyed.ReadTablePageAsync(PeopleTable, null, null, 100, cancellationToken: cancellationToken);
        using var keyedRun = keyedPage.Run;
        Assert.IsType<QueryOutcome.Completed>(await keyedRun.Completion);
        using var keyedRows = keyedRun.GetResultSet(0)!;

        Assert.Equal(EditLock.MaskedKey, keyedEditor.LockFor(keyedRows));
    }

    [Fact]
    public async Task ASavedRuleMasksTheRowsOnScreenButNotARevealedRun()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var saved = await SaveAsync();
        await using var session = await ConnectAsync(saved);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        using var onScreen = await RunAsync(editor, People);
        using var revealed = await RunAsync(editor, People, reveal: true);

        await _core.Library.SaveAsync(saved with { MaskingRules = [Rule("note", MaskStyle.Full)] }, ConnectionSecrets.None);

        Assert.True(onScreen.Remask());
        Assert.Equal([null, Bullets, Bullets], Column(onScreen, 2));
        Assert.Equal(MaskStyle.Full, onScreen.GetColumns()[2].Masked);
        Assert.False(onScreen.Remask());
        Assert.False(revealed.Remask());
        Assert.Equal("中文", revealed.GetCellText(2, 2));
    }

    [Fact]
    public async Task TheShareSheetStartsFromTheRulesThenTheDetectors()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var ruled = await ConnectAsync(await SaveAsync(Rule("people.name", MaskStyle.Email)));
        await using var ruledEditor = await ruled.OpenEditorAsync(cancellationToken);
        using var ruledRows = await RunAsync(ruledEditor, "SELECT id, name, 'x' AS tag FROM people ORDER BY id");
        await using var plain = await ConnectAsync(await SaveAsync());
        await using var plainEditor = await plain.OpenEditorAsync(cancellationToken);
        using var plainRows = await RunAsync(plainEditor, "SELECT id, name, 'ann@example.com' AS contact_email FROM people");

        var fromRules = await ruledRows.GetShareMaskingAsync(3, 1_000);
        var detected = await plainRows.GetShareMaskingAsync(3, 1_000);

        Assert.Equal(new ShareColumnMasking("id", null, null), fromRules[0]);
        Assert.Equal(new ShareColumnMasking("name", MaskStyle.Email, null), fromRules[1]);
        // No table column can be named for a literal, so a connection with rules sends it as Full.
        Assert.Equal(new ShareColumnMasking("tag", MaskStyle.Full, null) { Untraced = true }, fromRules[2]);
        Assert.Equal(new ShareColumnMasking("name", null, null), detected[1]);
        Assert.Equal(
            new ShareColumnMasking("contact_email", null, new MaskSuggestion(MaskStyle.Email, new MaskReason.ColumnName("email"))),
            detected[2]);
    }

    [Fact]
    public async Task ThePreviewShowsWhatTheLinkSends()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(await SaveAsync(Rule("people.name", MaskStyle.LastFour)));
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        using var rows = await RunAsync(editor, People);

        using var preview = await rows.GetSharePreviewAsync(
            3,
            2,
            [ShareColumnChoice.Remove.Instance, ShareColumnChoice.Keep.Instance, new ShareColumnChoice.Mask(MaskStyle.Null)]);

        Assert.Equal(["name", "note"], preview.GetColumns().Select(column => column.Name));
        Assert.Equal([MaskStyle.LastFour, MaskStyle.Null], preview.GetColumns().Select(column => column.Masked));
        Assert.Equal(2, preview.RowCount);
        Assert.Equal([Bullets, "••••race"], Column(preview, 0));
        Assert.Equal([null, null], Column(preview, 1));
    }

    [Fact]
    public async Task TheSummarySaysWhatALinkSendsAndWhyAValueTooLargeStopsIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await ConnectAsync(await SaveAsync());
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        using var rows = await RunAsync(editor, "SELECT id, name, printf('%.300000c', 'x') AS blob FROM people ORDER BY id");
        ShareColumnChoice[] keep = [ShareColumnChoice.Keep.Instance, ShareColumnChoice.Keep.Instance, ShareColumnChoice.Keep.Instance];
        ShareColumnChoice[] removed = [ShareColumnChoice.Keep.Instance, ShareColumnChoice.Keep.Instance, ShareColumnChoice.Remove.Instance];

        var tooLarge = await rows.GetShareSummaryAsync(3, 1_000, keep);
        var sends = await rows.GetShareSummaryAsync(3, 2, removed);
        var masked = await rows.GetShareSummaryAsync(3, 1_000, [.. removed[..2], new ShareColumnChoice.Mask(MaskStyle.Full)]);

        Assert.Equal(new ShareSummary(0, 3, false, new ShareTooLarge.Cell("blob")), tooLarge);
        Assert.Equal(new ShareSummary(2, 2, false, null), sends);
        Assert.Equal(new ShareSummary(3, 3, false, null), masked);
    }

    [Fact]
    public async Task OnlyAStatementThatReadsCountsAsReadOnly()
    {
        await using var session = await ConnectAsync(await SaveAsync());

        Assert.True(session.ReadsOnly(People));
        Assert.False(session.ReadsOnly("UPDATE people SET note = 'x'"));
        Assert.False(session.ReadsOnly("SELECT 1; DELETE FROM people"));
        Assert.False(session.ReadsOnly(string.Empty));
    }

    [Fact]
    public void PersonalDataInTheSqlNamesItsKindAndLine()
    {
        var hits = ShareLinks.ScanSqlForPersonalData("SELECT *\nFROM people WHERE note = 'ann@example.com' -- 'bob@example.com'");

        Assert.Equal([new PersonalDataHit(SensitiveKind.Email, 2)], hits);
        Assert.Empty(ShareLinks.ScanSqlForPersonalData("SELECT \"ann@example.com\" FROM people"));
    }
}
