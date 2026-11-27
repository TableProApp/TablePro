namespace TablePro.Interop.Tests;

public sealed class CompletionTests
{
    [Fact]
    public async Task ATablePlaceOffersTheFilesTablesQuotedWhereABareNameWouldNotRead()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("CREATE TABLE \"Order Items\" (id INTEGER, quantity INTEGER)");
        var cancellationToken = TestContext.Current.CancellationToken;
        // The catalog was read when the file opened, before the table was made.
        await database.Session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        const string Text = "SELECT * FROM pe";

        using var completion = await database.Session.CompleteAsync(
            Text, Text.Length, asked: false, cancellationToken: cancellationToken);

        Assert.NotNull(completion);
        Assert.Equal((14, "pe"), (completion.WordStart, completion.Word));
        var first = completion.Rank("pe", 10).Items[0];
        Assert.Equal(("people", CompletionKind.Table), (first.Label, first.Kind));
        Assert.Equal<MatchedSpan>([new MatchedSpan(0, 2)], first.Matched);
        var quoted = Assert.Single(completion.Rank("ord", 10).Items, item => item.Label == "Order Items");
        Assert.Equal("\"Order Items\"", quoted.InsertText);
    }

    [Fact]
    public async Task AnAliasDotOffersItsTablesColumnsInTheTablesOrder()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var cancellationToken = TestContext.Current.CancellationToken;
        await database.Session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);

        using var completion = await database.Session.CompleteAsync(
            "SELECT p. FROM people p", "SELECT p.".Length, asked: false, cancellationToken: cancellationToken);

        Assert.NotNull(completion);
        var page = completion.Rank(string.Empty, 50);
        Assert.Equal<string>(["id", "name", "note"], page.Items.Select(item => item.Label));
        Assert.All(page.Items, item => Assert.Equal(CompletionKind.Column, item.Kind));
        Assert.Equal("people", page.Items[0].Table?.Name);
        Assert.False(string.IsNullOrEmpty(page.Items[0].DataType));
    }

    [Fact]
    public async Task AKeywordFollowsTheCaseTypedAndOpensOnlyWhenAskedWithNothingTyped()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        var cancellationToken = TestContext.Current.CancellationToken;
        await database.Session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);

        var unasked = await database.Session.CompleteAsync(
            "SELECT ", 7, asked: false, cancellationToken: cancellationToken);
        using var asked = await database.Session.CompleteAsync(
            "SELECT ", 7, asked: true, cancellationToken: cancellationToken);
        var inString = await database.Session.CompleteAsync(
            "SELECT 'pe", 10, asked: true, cancellationToken: cancellationToken);

        Assert.Null(unasked);
        Assert.Null(inString);
        Assert.NotNull(asked);
        Assert.Equal("select", asked.Rank("sel", 1).Items[0].InsertText);
        Assert.Equal("SELECT", asked.Rank("SEL", 1).Items[0].InsertText);
        var page = asked.Rank(string.Empty, 1000);
        Assert.Contains(page.Items, item => item.Label == "people" && item.Kind == CompletionKind.Table);
        Assert.True(page.Total >= page.Items.Count);
    }

    [Fact]
    public async Task ADecomposedNameReplacesItsWholePrefix()
    {
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("CREATE TABLE \"cafés\" (id INTEGER)");
        var cancellationToken = TestContext.Current.CancellationToken;
        await database.Session.RefreshObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        const string Text = "SELECT * FROM café";

        using var completion = await database.Session.CompleteAsync(
            Text, Text.Length, asked: true, cancellationToken: cancellationToken);

        Assert.NotNull(completion);
        Assert.Equal((14, "café"), (completion.WordStart, completion.Word));
        Assert.Equal("cafés", Assert.Single(completion.Rank(completion.Word, 10).Items).Label);
    }

    [Fact]
    public void AFormatReflowsAStatementAndKeepsTheCaretInUtf16Units()
    {
        const string Text = "select '😀' as a, b from t where a = 1";

        var formatted = SqlFormatter.Format(SqlGrammar.Sqlite, Text, Text.IndexOf("b from", StringComparison.Ordinal));

        Assert.Contains('\n', formatted.Text);
        Assert.StartsWith("b", formatted.Text[formatted.Caret..], StringComparison.Ordinal);
        Assert.Equal(Text.Where(c => !char.IsWhiteSpace(c)), formatted.Text.Where(c => !char.IsWhiteSpace(c)));
    }

    [Fact]
    public void AStatementTheFormatterWouldChangeIsKeptAsTyped()
    {
        const string Text = "SET @x += 1";

        Assert.Equal(new FormattedSql(Text, 3), SqlFormatter.Format(SqlGrammar.MsSql, Text, 3));
    }

    [Theory]
    [InlineData("-- select a,b from t", 3)]
    [InlineData("select 'select a,b from t'", 8)]
    [InlineData("/* select a,b from t */", 3)]
    public void ASelectionInsideACommentOrStringKeepsItsMeaning(string text, int start)
    {
        const string Selected = "select a,b from t";

        Assert.Equal(Selected, SqlFormatter.FormatSelection(SqlGrammar.Sqlite, text, start, start + Selected.Length));
    }

    [Fact]
    public void ASelectedStatementIsReflowedWithoutItsNeighbours()
    {
        const string Selected = "select a,b from t";
        const string Before = "select '😀'; ";

        var result = SqlFormatter.FormatSelection(
            SqlGrammar.Sqlite, Before + Selected + "; select 2", Before.Length, Before.Length + Selected.Length);

        Assert.Contains('\n', result);
        Assert.Equal(Selected.Where(c => !char.IsWhiteSpace(c)), result.Where(c => !char.IsWhiteSpace(c)));
    }
}
