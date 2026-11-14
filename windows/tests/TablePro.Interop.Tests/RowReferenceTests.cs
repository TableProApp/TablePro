namespace TablePro.Interop.Tests;

public sealed class RowReferenceTests
{
    private const string Schema = """
        CREATE TABLE parent (code TEXT NOT NULL, region INTEGER NOT NULL, PRIMARY KEY (code, region));
        CREATE TABLE child (id INTEGER PRIMARY KEY, parent_code TEXT, parent_region INTEGER,
            FOREIGN KEY (parent_code, parent_region) REFERENCES parent(code, region));
        INSERT INTO parent VALUES ('x'' OR 1=1 --', 7), ('x'' OR 1=1 --', 8), ('', 9);
        INSERT INTO child VALUES (1, 'x'' OR 1=1 --', 7), (2, 'x'' OR 1=1 --', 8), (3, NULL, 7), (4, '', 9);
        """;

    private static readonly TableName Child = new(null, "child");

    [Fact]
    public async Task ACompositeKeyLeadsToItsRowAndBackWithEveryValueBound()
    {
        var cancel = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync(Schema);
        using var children = await ReadAsync(database.Session, Child, null, cancel);
        using var keys = await database.Session.ReadTableKeysAsync(Child, cancel);

        var references = keys.GetRowReferences(children, 0, "parent_code");
        var choice = Assert.Single(references.Referenced);
        Assert.Empty(references.Referencing);
        Assert.Equal(new TableName(null, "parent"), choice.Table);
        Assert.Equal(["parent_code", "parent_region"], choice.Columns);
        Assert.True(keys.GetRowReferences(children, 0, "id").IsEmpty);
        var rows = Assert.IsType<FollowedReference.Rows>(keys.Follow(children, 0, choice));
        Assert.Equal(new TableName(null, "parent"), rows.Table);
        Assert.Null(rows.Filter.RawSql);
        Assert.Equal(FilterCombinator.And, rows.Filter.Combinator);
        Assert.Equal([
            new FilterRule("code", FilterOperator.Equal, new FilterValue.One("x' OR 1=1 --")),
            new FilterRule("region", FilterOperator.Equal, new FilterValue.One("7")),
        ], rows.Filter.Rules);

        using var parent = await ReadAsync(database.Session, rows.Table, rows.Filter, cancel);
        Assert.Equal(1, parent.RowCount);
        Assert.Equal("7", parent.GetCellText(0, 1));
        using var parentKeys = await database.Session.ReadTableKeysAsync(rows.Table, cancel);
        var incoming = Assert.Single(parentKeys.GetRowReferences(parent, 0, null).Referencing);
        Assert.Equal(Child, incoming.Table);
        var back = Assert.IsType<FollowedReference.Rows>(parentKeys.Follow(parent, 0, incoming));
        using var child = await ReadAsync(database.Session, back.Table, back.Filter, cancel);
        Assert.Equal(1, child.RowCount);
        Assert.Equal("1", child.GetCellText(0, 0));
    }

    [Fact]
    public async Task ANullPartLeadsNowhereWhileAnEmptyTextAndASortedRowKeepTheirValues()
    {
        var cancel = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync(Schema);
        using var children = await ReadAsync(database.Session, Child, null, cancel);
        using var keys = await database.Session.ReadTableKeysAsync(Child, cancel);

        Assert.True(keys.GetRowReferences(children, 2, null).IsEmpty);
        using var sorted = await children.SortedAsync(0, ascending: false);
        var choice = Assert.Single(keys.GetRowReferences(sorted, 0, null).Referenced);
        var rows = Assert.IsType<FollowedReference.Rows>(keys.Follow(sorted, 0, choice));
        Assert.Equal(new FilterValue.One(string.Empty), rows.Filter.Rules[0].Value);
        using var parent = await ReadAsync(database.Session, rows.Table, rows.Filter, cancel);
        Assert.Equal("9", parent.GetCellText(0, 1));
        Assert.Equal("ffi.out_of_range", Assert.Throws<TableProException>(() => keys.GetRowReferences(children, 99, null)).Code);
        Assert.Equal("ffi.out_of_range", Assert.Throws<TableProException>(() => keys.Follow(children, 2, choice)).Code);
    }

    [Fact]
    public async Task AKeyThatComparesOtherwiseIsOfferedAndRefusedNamingTheTable()
    {
        var cancel = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("""
            CREATE TABLE parent (code TEXT COLLATE NOCASE PRIMARY KEY);
            CREATE TABLE child (code TEXT REFERENCES parent(code));
            INSERT INTO parent VALUES ('ABC');
            INSERT INTO child VALUES ('abc');
            """);
        var table = new TableName(null, "parent");
        using var parents = await ReadAsync(database.Session, table, null, cancel);
        using var keys = await database.Session.ReadTableKeysAsync(table, cancel);

        var choice = Assert.Single(keys.GetRowReferences(parents, 0, null).Referencing);

        Assert.Equal(
            new FollowedReference.Refused(ReferenceRefusal.ComparedOtherwise, "child"),
            keys.Follow(parents, 0, choice));
    }

    [Fact]
    public async Task ACellReadsOnlyItsStartAndABinaryCellItsFirstBytesWithItsLength()
    {
        var cancel = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("""
            CREATE TABLE files (id INTEGER PRIMARY KEY, body BLOB, note TEXT);
            INSERT INTO files VALUES (1, X'89504E47', 'line one' || char(10) || 'line two'), (2, NULL, NULL);
            """);
        using var files = await ReadAsync(database.Session, new TableName(null, "files"), null, cancel);

        var first = files.GetCellBytes(0, 1, 2)!;
        Assert.Equal([0x89, 0x50], first.Bytes.ToArray());
        Assert.Equal(4, first.Length);
        Assert.Null(files.GetCellBytes(0, 2, 100));
        Assert.Null(files.GetCellBytes(1, 1, 100));
        Assert.Equal(new CellTextHead("line one\nline two", false), files.GetCellTextHead(0, 2, 100));
        Assert.Equal(new CellTextHead("line", true), files.GetCellTextHead(0, 2, 4));
        Assert.Null(files.GetCellTextHead(1, 2, 100));
        Assert.Equal("ffi.out_of_range", Assert.Throws<TableProException>(() => files.GetCellBytes(5, 1, 100)).Code);
    }

    private static async Task<ResultSet> ReadAsync(
        DatabaseSession session, TableName table, TableFilter? filter, CancellationToken cancel)
    {
        var page = await session.ReadTablePageAsync(table, null, filter, 100, cancellationToken: cancel);
        using var run = page.Run;
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        return Assert.IsType<ResultSet>(run.GetResultSet(0));
    }
}
