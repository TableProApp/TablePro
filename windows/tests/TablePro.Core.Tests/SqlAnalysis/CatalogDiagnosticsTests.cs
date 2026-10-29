using System.Globalization;
using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using static TablePro.Core.Tests.SqlAnalysis.Analysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>
/// Names checked against the catalog. The rule is the macOS one taken further: say nothing unless the catalog makes
/// the mistake certain, since a false warning teaches the user to ignore every warning.
/// </summary>
public sealed class CatalogDiagnosticsTests
{
    [Fact]
    public void AnUnknownTableIsAWarningOnItsName()
    {
        const string text = "SELECT * FROM userz";
        var diagnostic = Assert.Single(Diagnose(text, caret: 0));
        Assert.Equal(SqlDiagnosticCode.UnknownTable, diagnostic.Code);
        Assert.Equal(SqlDiagnosticSeverity.Warning, diagnostic.Severity);
        Assert.Equal(Range(text, "userz"), diagnostic.Range);
        Assert.Equal("Unknown table 'userz'.", diagnostic.Message);
    }

    [Fact]
    public void DiagnosticsFollowTheUiLanguage()
    {
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");
            var diagnostic = Assert.Single(Diagnose("SELECT * FROM userz", caret: 0));

            Assert.Equal("Table «\x00A0userz\x00A0» inconnue.", diagnostic.Message);
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }

    [Fact]
    public void ANameBeingTypedAtTheCaretIsNotFlaggedUntilTheCaretLeaves()
    {
        const string text = "SELECT * FROM ord";
        var analysis = Analyze(text, caret: text.Length);
        Assert.Empty(analysis.Diagnostics);
        Assert.Empty(Diagnose(text, caret: At(text, "ord") + 1));
        Assert.True(analysis.CaretChangesResult(0));
        Assert.False(analysis.CaretChangesResult(At(text, "ord")));
        Assert.Single(Diagnose(text, caret: 0));
    }

    [Fact]
    public void KnownTablesViewsAndCaseVariantsAreQuiet()
    {
        Assert.Empty(Diagnose("SELECT * FROM USERS u JOIN Orders o ON o.user_id = u.id JOIN active_users a ON a.id = u.id"));
    }

    [Fact]
    public void NothingIsUnknownBeforeTheCatalogLoads()
    {
        Assert.Empty(Diagnose("SELECT * FROM userz", catalog: CompletionCatalog.Empty));
    }

    [Fact]
    public void SchemaQualifiedTablesAreNotChecked()
    {
        Assert.Empty(Diagnose("SELECT * FROM archive.userz"));
    }

    [Fact]
    public void CommonTableExpressionsTableFunctionsAndSubqueriesAreNotUnknown()
    {
        Assert.Empty(Diagnose("WITH recent AS (SELECT * FROM orders) SELECT * FROM recent r JOIN generate_series(1, 2) g ON true JOIN (SELECT 1 AS x) s ON true"));
    }

    [Fact]
    public void TablesTheScriptCreatesAreKnown()
    {
        Assert.Empty(Diagnose("CREATE TEMP TABLE scratch (id int);\rINSERT INTO scratch SELECT id FROM users;\rSELECT * FROM scratch;"));
        Assert.Empty(Diagnose("SELECT * INTO backup FROM users;\rSELECT * FROM backup;", SqlServerDialect.Instance));
    }

    [Fact]
    public void SystemCatalogTablesAreNotUnknown()
    {
        Assert.Empty(Diagnose("SELECT * FROM pg_stat_activity"));
        Assert.Empty(Diagnose("SELECT * FROM sqlite_master", SqliteDialect.Instance));
        Assert.Empty(Diagnose("SELECT 1 FROM dual", OracleDialect.Instance));
        Assert.Empty(Diagnose("SELECT * FROM all_tables", OracleDialect.Instance));
        Assert.Empty(Diagnose("SELECT * FROM sysobjects", SqlServerDialect.Instance));
    }

    [Fact]
    public void OnlyDataStatementsAreChecked()
    {
        Assert.Empty(Diagnose("DROP TABLE userz"));
        Assert.Empty(Diagnose("CREATE VIEW v AS SELECT * FROM userz"));
        Assert.Empty(Diagnose("REVOKE SELECT ON users FROM someone"));
        Assert.Single(Diagnose("EXPLAIN SELECT * FROM userz", caret: 0));
    }

    [Fact]
    public void AStatementThatChangesDatabaseStopsTheChecksAfterIt()
    {
        const string text = "SELECT * FROM userz;\rUSE other;\rSELECT * FROM elsewhere;";
        var diagnostic = Assert.Single(Diagnose(text, MySqlDialect.Instance));
        Assert.Equal(Range(text, "userz"), diagnostic.Range);
    }

    [Fact]
    public void AnUnknownColumnOfALoadedTableIsAWarning()
    {
        const string text = "SELECT u.nmae FROM users u";
        var diagnostic = Assert.Single(Diagnose(text));
        Assert.Equal(SqlDiagnosticCode.UnknownColumn, diagnostic.Code);
        Assert.Equal(Range(text, "nmae"), diagnostic.Range);
        Assert.Equal("Table 'users' has no column 'nmae'.", diagnostic.Message);
    }

    [Fact]
    public void ColumnsOfATableWhoseStructureIsNotLoadedAreNotChecked()
    {
        Assert.Empty(Diagnose("SELECT a.anything FROM active_users a"));
    }

    [Fact]
    public void KnownAndPseudoColumnsAreQuiet()
    {
        Assert.Empty(Diagnose("SELECT u.ID, u.name, u.ctid, users.email, u.* FROM users u, users"));
        Assert.Empty(Diagnose("SELECT o.rowid FROM orders o", SqliteDialect.Instance));
    }

    [Fact]
    public void AnUnknownQualifierIsAWarningOnlyWhenEveryTableIsFullyKnown()
    {
        const string text = "SELECT x.id FROM users u JOIN orders o ON o.user_id = u.id";
        var diagnostic = Assert.Single(Diagnose(text));
        Assert.Equal(SqlDiagnosticCode.UnknownQualifier, diagnostic.Code);
        Assert.Equal(Range(text, "x"), diagnostic.Range);
        Assert.Equal("Unknown table or alias 'x'.", diagnostic.Message);

        // active_users has no loaded columns, so x may be one of them with a composite or struct type.
        Assert.Empty(Diagnose("SELECT x.id FROM users u JOIN active_users a ON a.id = u.id"));
    }

    [Fact]
    public void AQualifierNamingAColumnIsStructAccessNotAMistake()
    {
        var catalog = new CompletionCatalog(
            [],
            [("events", false)],
            new Dictionary<string, IReadOnlyList<(string Name, string Type)>> { ["events"] = [("payload", "STRUCT(a INT)")] });
        Assert.Empty(Diagnose("SELECT payload.a FROM events", DuckDbDialect.Instance, catalog));
    }

    [Fact]
    public void PseudoTablesSchemasAndCommonTableExpressionsAreKnownQualifiers()
    {
        Assert.Empty(Diagnose("INSERT INTO users (id, name) VALUES (1, 'a') ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name"));
        Assert.Empty(Diagnose("WITH c AS (SELECT 1 AS n) SELECT c.n FROM c"));
        Assert.Empty(Diagnose("SELECT public.users.id FROM users"));
    }

    [Fact]
    public void ATableNamedWhereItsAliasIsRequiredIsAnUnknownQualifier()
    {
        const string text = "SELECT users.id FROM users u";
        Assert.Equal([SqlDiagnosticCode.UnknownQualifier], Codes(text));
    }

    [Fact]
    public void AnInnerQueryLevelCheckedAgainstItsOwnTables()
    {
        const string text = "SELECT * FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_idd = u.id)";
        var diagnostic = Assert.Single(Diagnose(text));
        Assert.Equal(Range(text, "user_idd"), diagnostic.Range);
    }
}
