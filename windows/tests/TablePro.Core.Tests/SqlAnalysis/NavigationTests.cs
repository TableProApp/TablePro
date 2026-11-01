using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using static TablePro.Core.Tests.SqlAnalysis.Analysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>Go to definition, hover and references.</summary>
public sealed class NavigationTests
{
    private const string Join = "SELECT u.name, o.total FROM users u JOIN orders o ON o.user_id = u.id";

    [Fact]
    public void ATableNameLeadsToTheCatalogTable()
    {
        var symbol = Analyze(Join).SymbolAt(At(Join, "users") + 2)!;
        Assert.Equal(SqlSymbolKind.Table, symbol.Kind);
        Assert.Equal(Range(Join, "users"), symbol.Range);
        Assert.Equal(new SqlCatalogDefinition(null, "users", IsView: false), symbol.Definition);
        Assert.Equal(3, symbol.Columns!.Count);
    }

    [Fact]
    public void AViewIsAView()
    {
        const string text = "SELECT * FROM active_users";
        var symbol = Analyze(text).SymbolAt(At(text, "active"))!;
        Assert.Equal(SqlSymbolKind.View, symbol.Kind);
        Assert.Equal(new SqlCatalogDefinition(null, "active_users", IsView: true), symbol.Definition);
    }

    [Fact]
    public void AnUnknownTableLeadsNowhereButASchemaQualifiedOneStillOpens()
    {
        Assert.Null(Analyze("SELECT * FROM userz").SymbolAt(15)!.Definition);
        const string text = "SELECT * FROM archive.logs";
        Assert.Equal(new SqlCatalogDefinition("archive", "logs", IsView: false), Analyze(text).SymbolAt(At(text, "logs"))!.Definition);
    }

    [Fact]
    public void AQualifierJumpsToTheAliasAndTheAliasOpensTheTable()
    {
        var analysis = Analyze(Join);
        var qualifier = analysis.SymbolAt(At(Join, "o.user_id"))!;
        Assert.Equal(SqlSymbolKind.Alias, qualifier.Kind);
        Assert.Equal(new SqlTextDefinition(At(Join, "o ON"), 1), qualifier.Definition);
        Assert.Equal("orders", qualifier.Table);

        var declaration = analysis.SymbolAt(At(Join, "o ON"))!;
        Assert.Equal(SqlSymbolKind.Alias, declaration.Kind);
        Assert.Equal(new SqlCatalogDefinition(null, "orders", IsView: false), declaration.Definition);
    }

    [Fact]
    public void AColumnLeadsToItsTableAndColumn()
    {
        var symbol = Analyze(Join).SymbolAt(At(Join, "total"))!;
        Assert.Equal(SqlSymbolKind.Column, symbol.Kind);
        Assert.Equal("numeric", symbol.DataType);
        Assert.Equal(new SqlCatalogDefinition(null, "orders", IsView: false, Column: "total"), symbol.Definition);
    }

    [Fact]
    public void AnUnqualifiedColumnIsFoundInTheStatementsTables()
    {
        const string text = "SELECT email FROM users WHERE id = 1";
        var symbol = Analyze(text).SymbolAt(At(text, "email"))!;
        Assert.Equal(SqlSymbolKind.Column, symbol.Kind);
        Assert.Equal("users", symbol.Table);
        Assert.Equal("text", symbol.DataType);
        Assert.Null(Analyze("SELECT nothing FROM users").SymbolAt(8));
    }

    [Fact]
    public void ACommonTableExpressionUseJumpsToItsDefinition()
    {
        const string text = "WITH big AS (SELECT * FROM orders) SELECT b.total FROM big b, big";
        var analysis = Analyze(text);
        var cte = new SqlTextDefinition(At(text, "big"), 3);
        Assert.Equal(cte, analysis.SymbolAt(At(text, "big", 2))!.Definition);
        Assert.Equal(SqlSymbolKind.CommonTableExpression, analysis.SymbolAt(At(text, "big", 2))!.Kind);

        // b.total leads to the alias b, and the alias to the definition of big.
        Assert.Equal(new SqlTextDefinition(At(text, "b,"), 1), analysis.SymbolAt(At(text, "b.total"))!.Definition);
        Assert.Equal(cte, analysis.SymbolAt(At(text, "b,"))!.Definition);
    }

    [Fact]
    public void TheOffsetJustAfterANameCounts()
    {
        Assert.Equal(SqlSymbolKind.Table, Analyze(Join).SymbolAt(Range(Join, "users").End)!.Kind);
    }

    [Fact]
    public void KeywordsAndLiteralsHaveNoSymbol()
    {
        Assert.Null(Analyze(Join).SymbolAt(2));
        Assert.Null(Analyze("SELECT 'users' FROM users").SymbolAt(9));
    }

    [Fact]
    public void HoverDescribesTablesAliasesAndColumns()
    {
        var analysis = Analyze(Join);
        var table = analysis.HoverAt(At(Join, "users"))!;
        Assert.Equal("Table users", table.Title);
        Assert.Equal("id     integer\nname   text\nemail  text", table.Detail);

        Assert.Equal("o: alias of table orders", analysis.HoverAt(At(Join, "o.total"))!.Title);
        Assert.Equal("Column orders.total", analysis.HoverAt(At(Join, "total"))!.Title);
        Assert.Equal("numeric", analysis.HoverAt(At(Join, "total"))!.Detail);
    }

    [Fact]
    public void HoverCarriesTheDiagnosticsUnderThePointer()
    {
        const string text = "SELECT u.nmae FROM users u";
        var hover = Analyze(text).HoverAt(At(text, "nmae") + 1)!;
        Assert.Equal(SqlDiagnosticCode.UnknownColumn, Assert.Single(hover.Diagnostics).Code);
        Assert.Equal("Column users.nmae", hover.Title);
        Assert.Null(Analyze(text).HoverAt(1));
    }

    [Fact]
    public void HoverAtTheCaretReachesTheRangeJustBeforeIt()
    {
        const string text = "SELECT * FROM users)";
        var analysis = Analyze(text);
        Assert.Null(analysis.HoverAt(text.Length));
        Assert.Single(analysis.HoverAt(text.Length, atCaret: true)!.Diagnostics);
    }

    [Fact]
    public void ALongColumnListIsCut()
    {
        var columns = Enumerable.Range(1, 25).Select(i => ($"c{i}", "int")).ToArray();
        var catalog = new CompletionCatalog([], [("wide", false)], new Dictionary<string, IReadOnlyList<(string Name, string Type)>> { ["wide"] = columns });
        var detail = Analyze("SELECT * FROM wide", catalog: catalog).HoverAt(15)!.Detail!;
        Assert.Equal(21, detail.Split('\n').Length);
        Assert.EndsWith("and 5 more", detail, StringComparison.Ordinal);
    }

    [Fact]
    public void AnAliasReferencesItsDeclarationAndEveryQualifierOfIt()
    {
        var references = Analyze(Join).ReferencesAt(At(Join, "u.id"));
        Assert.Equal([One(Join, "u.name"), One(Join, "u JOIN"), One(Join, "u.id")], references);
    }

    [Fact]
    public void AnAliasReferenceStaysInsideItsQueryLevel()
    {
        const string text = "SELECT t.id FROM users t WHERE EXISTS (SELECT 1 FROM orders t WHERE t.user_id = 1)";
        var references = Analyze(text).ReferencesAt(At(text, "t.user_id"));
        Assert.Equal([One(text, "t WHERE", 1), One(text, "t.user_id")], references);
    }

    /// <summary>The first character of the <paramref name="nth"/> occurrence, for one-letter names.</summary>
    private static SqlTextRange One(string text, string needle, int nth = 0) => new(At(text, needle, nth), 1);

    [Fact]
    public void ATableReferencesEveryUseAcrossTheScript()
    {
        const string text = "SELECT * FROM users;\rSELECT users.id FROM users;\rSELECT * FROM users u;";
        var references = Analyze(text).ReferencesAt(At(text, "users"));
        Assert.Equal([Range(text, "users", 0), Range(text, "users", 1), Range(text, "users", 2), Range(text, "users", 3)], references);
    }

    [Fact]
    public void ACommonTableExpressionReferencesItsUses()
    {
        const string text = "WITH big AS (SELECT 1) SELECT big.x FROM big";
        Assert.Equal([Range(text, "big", 0), Range(text, "big", 1), Range(text, "big", 2)], Analyze(text).ReferencesAt(At(text, "big", 2)));
    }

    [Fact]
    public void AColumnReferencesQualifiedAndPlainUses()
    {
        const string text = "SELECT u.email, email FROM users u WHERE email <> ''";
        var references = Analyze(text).ReferencesAt(At(text, "email"));
        Assert.Equal([Range(text, "email", 0), Range(text, "email", 1), Range(text, "email", 2)], references);
    }

    [Fact]
    public void NothingIsReferencedOffAName()
    {
        Assert.Empty(Analyze(Join).ReferencesAt(1));
    }

    [Fact]
    public void TheCatalogDefinitionMatchesSidebarObjects()
    {
        var unqualified = new SqlCatalogDefinition(null, "users", IsView: false);
        Assert.True(unqualified.Matches("public", "USERS"));
        Assert.False(unqualified.Matches("public", "orders"));
        var qualified = new SqlCatalogDefinition("sales", "users", IsView: false);
        Assert.True(qualified.Matches("SALES", "users"));
        Assert.False(qualified.Matches("public", "users"));
    }

    [Fact]
    public void ACommandLanguageHasNoHover()
    {
        Assert.Null(Analyze("GET users", RedisDialect.Instance).HoverAt(5));
    }
}
