using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using static TablePro.Core.Tests.SqlAnalysis.Analysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>How a statement's tables, aliases and common table expressions are read and resolved.</summary>
public sealed class NameResolutionTests
{
    private static SqlStatementModel Model(string text, SqlDialect? dialect = null) =>
        Analyze(text, dialect).StatementAt(0) ?? throw new InvalidOperationException("no statement");

    [Fact]
    public void TablesAndAliasesAreReadFromFromAndJoin()
    {
        var model = Model("SELECT u.name, o.total FROM users u JOIN orders AS o ON o.user_id = u.id");
        Assert.Equal(["users", "orders"], model.Tables.Select(t => t.Name));
        Assert.Equal(["u", "o"], model.Tables.Select(t => t.Alias));
        Assert.Equal("SELECT", model.Verb);
        Assert.True(model.IsDataStatement);
        Assert.Same(model.Tables[0], model.ResolveQualifier("U", 0));
    }

    [Fact]
    public void CommaListsSchemasAndQuotedNamesAreRead()
    {
        var model = Model("SELECT * FROM public.users AS \"U\", sales.orders o2, \"Odd \"\"Name\"\"\"");
        Assert.Equal(["users", "orders", "Odd \"Name\""], model.Tables.Select(t => t.Name));
        Assert.Equal(["public", "sales", null], model.Tables.Select(t => t.Schema));
        Assert.Equal(["U", "o2", null], model.Tables.Select(t => t.Alias));
    }

    [Fact]
    public void ClauseWordsAreNotAliases()
    {
        var model = Model("SELECT * FROM users WHERE id = 1 ORDER BY name LIMIT 5");
        Assert.Null(Assert.Single(model.Tables).Alias);
        Assert.Null(Assert.Single(Model("SELECT * FROM users LEFT JOIN orders ON true").Tables, t => t.Name == "users").Alias);
        Assert.Null(Model("SELECT * FROM users QUALIFY x = 1").Tables[0].Alias);
    }

    [Fact]
    public void UpdateInsertDeleteAndMergeTargetsAreTables()
    {
        Assert.Equal(["users"], Model("UPDATE users SET name = 'x' WHERE id = 1").Tables.Select(t => t.Name));
        Assert.Equal(["orders", "users"], Model("INSERT INTO orders (user_id) SELECT id FROM users").Tables.Select(t => t.Name));
        Assert.Equal(["users"], Model("DELETE FROM users WHERE id = 1").Tables.Select(t => t.Name));
        Assert.Equal(["users", "orders"], Model("MERGE INTO users AS t USING orders AS s ON t.id = s.user_id WHEN MATCHED THEN UPDATE SET name = s.total").Tables.Select(t => t.Name));
    }

    [Fact]
    public void UpdateInsideAClauseIsNotATable()
    {
        var model = Model("INSERT INTO users (id) VALUES (1) ON DUPLICATE KEY UPDATE name = 'x'", MySqlDialect.Instance);
        Assert.Equal(["users"], model.Tables.Select(t => t.Name));
        Assert.Equal(["users"], Model("SELECT * FROM users FOR UPDATE").Tables.Select(t => t.Name));
        Assert.Equal(["users"], Model("INSERT INTO users (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name").Tables.Select(t => t.Name));
    }

    [Fact]
    public void AFromInsideAFunctionCallIsNotATableList()
    {
        var model = Model("SELECT EXTRACT(YEAR FROM created), SUBSTRING(name FROM 2), TRIM(BOTH ' ' FROM email) FROM users");
        Assert.Equal(["users"], model.Tables.Select(t => t.Name));
        Assert.Equal(["users"], Model("SELECT * FROM users WHERE a IS DISTINCT FROM b").Tables.Select(t => t.Name));
    }

    [Fact]
    public void ASubqueryIsItsOwnLevelWithItsAlias()
    {
        var model = Model("SELECT s.total FROM (SELECT o.total FROM orders o) AS s WHERE EXISTS (SELECT 1 FROM users u WHERE u.id = s.total)");
        var subquery = Assert.Single(model.Tables, t => t.Kind == SqlTableReferenceKind.Subquery);
        Assert.Equal("s", subquery.Alias);
        Assert.Equal(["orders", "users"], model.Tables.Where(t => t.Kind == SqlTableReferenceKind.Table).Select(t => t.Name));
    }

    [Fact]
    public void AnInnerAliasShadowsAnOuterOneWithTheSameName()
    {
        const string text = "SELECT t.id FROM users t WHERE EXISTS (SELECT 1 FROM orders t WHERE t.user_id = 1)";
        var analysis = Analyze(text);
        var model = analysis.StatementAt(0)!;
        Assert.Equal("orders", Assert.IsType<SqlSymbol>(analysis.SymbolAt(At(text, "t.user_id"))).Table);
        Assert.Equal("users", Assert.IsType<SqlSymbol>(analysis.SymbolAt(At(text, "t.id"))).Table);
        Assert.Equal(2, model.Tables.Count);
    }

    [Fact]
    public void ACorrelatedSubqueryReachesTheOuterAlias()
    {
        const string text = "SELECT * FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)";
        Assert.Equal("users", Analyze(text).SymbolAt(At(text, "u.id"))!.Table);
    }

    [Fact]
    public void CommonTableExpressionsAreDefinedAndReferenced()
    {
        const string text = "WITH RECURSIVE big (id) AS (SELECT id FROM orders WHERE total > 9), names AS MATERIALIZED (SELECT name FROM users) SELECT * FROM big b JOIN names ON true";
        var model = Model(text);
        Assert.Equal(["big", "names"], model.CommonTableExpressions.Select(c => c.Name));
        var big = Assert.Single(model.Tables, t => t.Name == "big");
        Assert.Equal(SqlTableReferenceKind.CommonTableExpression, big.Kind);
        Assert.Same(model.CommonTableExpressions[0], big.CommonTableExpression);
        Assert.Equal(SqlTableReferenceKind.CommonTableExpression, Assert.Single(model.Tables, t => t.Name == "names").Kind);
        Assert.Equal("SELECT", model.Verb);
    }

    [Fact]
    public void TableHintsAndOtherWithClausesAreNotCommonTableExpressions()
    {
        Assert.Empty(Model("SELECT * FROM users WITH (NOLOCK)", SqlServerDialect.Instance).CommonTableExpressions);
        Assert.Empty(Model("SELECT * FROM orders FETCH FIRST 5 ROWS WITH TIES").CommonTableExpressions);
    }

    [Fact]
    public void TableFunctionsAndTheirAliasesAreRead()
    {
        var model = Model("SELECT g FROM generate_series(1, 3) AS g, users u");
        Assert.Equal(SqlTableReferenceKind.Function, model.Tables[0].Kind);
        Assert.Equal("g", model.Tables[0].Alias);
        Assert.Equal("users", model.Tables[1].Name);
    }

    [Fact]
    public void AParenthesizedJoinStillNamesTables()
    {
        Assert.Equal(["users", "orders"], Model("SELECT * FROM (users u JOIN orders o ON o.user_id = u.id)").Tables.Select(t => t.Name));
    }

    [Fact]
    public void JoinUsingColumnsAreNotTables()
    {
        Assert.Equal(["users", "orders"], Model("SELECT * FROM users JOIN orders USING (id)").Tables.Select(t => t.Name));
    }

    [Fact]
    public void QualifiedNamesAreRead()
    {
        var model = Model("SELECT u.name, public.users.id, u.*, o.total::text FROM users u, orders o");
        Assert.Equal(["u", "users", "u", "o"], model.QualifiedReferences.Select(q => q.Qualifier));
        Assert.Equal(["name", "id", null, "total"], model.QualifiedReferences.Select(q => q.Column));
        Assert.Equal("public", model.QualifiedReferences[1].Schema);
    }

    [Fact]
    public void QualifiedFunctionsAndCastTypesAreNotColumns()
    {
        var model = Model("SELECT pg_catalog.now(), x::pg_catalog.int4, CAST(y AS pg_catalog.text) FROM users");
        Assert.Empty(model.QualifiedReferences);
    }

    [Fact]
    public void CreateStatementsRecordWhatTheyCreate()
    {
        Assert.Equal(["scratch"], Model("CREATE TEMP TABLE IF NOT EXISTS scratch (id int)").CreatedNames);
        Assert.Equal(["v"], Model("CREATE OR REPLACE VIEW public.v AS SELECT 1").CreatedNames);
        Assert.False(Model("CREATE VIEW v AS SELECT * FROM users").IsDataStatement);
    }

    [Fact]
    public void SelectIntoCreatesRatherThanReads()
    {
        var model = Model("SELECT * INTO backup FROM users");
        Assert.Equal(["users"], model.Tables.Select(t => t.Name));
        Assert.Equal(["backup"], model.CreatedNames);
    }

    [Fact]
    public void SchemaChangingStatementsAreRecognized()
    {
        Assert.True(Model("USE other", MySqlDialect.Instance).ChangesSchemaContext);
        Assert.True(Model("SET search_path TO other").ChangesSchemaContext);
        Assert.False(Model("SET timezone TO 'UTC'").ChangesSchemaContext);
    }

    [Fact]
    public void ACommandLanguageHasNoModels()
    {
        Assert.Null(Analyze("GET users", RedisDialect.Instance).SymbolAt(5));
    }
}
