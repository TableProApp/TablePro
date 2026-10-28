using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class OracleScriptTests
{
    private static string[] Split(string text) => OracleScript.Split(text).Select(s => s.Text).ToArray();

    [Fact]
    public void SqlStatementsEndAtSemicolonsWhichAreNotSent()
    {
        Assert.Equal(["SELECT 1 FROM dual", "UPDATE t SET a = 1"], Split("SELECT 1 FROM dual;\nUPDATE t SET a = 1;\n"));
    }

    [Fact]
    public void AnonymousBlockKeepsItsInnerSemicolonsUntilTheSlashLine()
    {
        const string script = "BEGIN\n  UPDATE t SET a = 1;\n  COMMIT;\nEND;\n/\nSELECT * FROM t;";

        Assert.Equal(["BEGIN\n  UPDATE t SET a = 1;\n  COMMIT;\nEND;", "SELECT * FROM t"], Split(script));
    }

    [Fact]
    public void DeclareBlockIsPlSql()
    {
        const string script = "declare\n  n number := 0;\nbegin\n  n := n + 1;\nend;\n/";

        Assert.Equal(["declare\n  n number := 0;\nbegin\n  n := n + 1;\nend;"], Split(script));
    }

    [Theory]
    [InlineData("CREATE OR REPLACE PROCEDURE p IS\nBEGIN\n  NULL;\nEND;")]
    [InlineData("CREATE FUNCTION f RETURN NUMBER IS\nBEGIN\n  RETURN 1;\nEND;")]
    [InlineData("CREATE OR REPLACE EDITIONABLE PACKAGE BODY pkg AS\n  PROCEDURE p IS BEGIN NULL; END;\nEND pkg;")]
    [InlineData("CREATE OR REPLACE NONEDITIONABLE PACKAGE pkg AS\n  PROCEDURE p;\nEND;")]
    [InlineData("CREATE OR REPLACE TRIGGER trg BEFORE INSERT ON t FOR EACH ROW\nBEGIN\n  :new.id := 1;\nEND;")]
    [InlineData("CREATE OR REPLACE TYPE point AS OBJECT (x NUMBER, y NUMBER);")]
    [InlineData("CREATE OR REPLACE AND COMPILE JAVA SOURCE NAMED \"Hello\" AS public class Hello { void a() { int x; } }")]
    public void StoredUnitsRunWholeUntilTheSlashLine(string unit)
    {
        Assert.Equal([unit, "SELECT 2 FROM dual"], Split(unit + "\n/\nSELECT 2 FROM dual;"));
    }

    [Theory]
    [InlineData("CREATE TABLE t (a NUMBER)")]
    [InlineData("CREATE OR REPLACE VIEW v AS SELECT 1 a FROM dual")]
    [InlineData("CREATE OR REPLACE FORCE EDITIONING VIEW v AS SELECT 1 a FROM dual")]
    [InlineData("CREATE UNIQUE INDEX ix ON t (a)")]
    public void OtherCreatesAreSql(string statement)
    {
        Assert.Equal([statement, "SELECT 2 FROM dual"], Split(statement + ";\nSELECT 2 FROM dual;"));
    }

    [Fact]
    public void SlashLineEndsASqlStatementWithoutSemicolon()
    {
        Assert.Equal(["SELECT 1 FROM dual", "SELECT 2 FROM dual"], Split("SELECT 1 FROM dual\n/\nSELECT 2 FROM dual\n  /  \n"));
    }

    [Fact]
    public void SlashInsideALineIsDivision()
    {
        Assert.Equal(["SELECT 4 / 2 FROM dual", "BEGIN x := 4\n / 2; END;"], Split("SELECT 4 / 2 FROM dual;\nBEGIN x := 4\n / 2; END;"));
    }

    [Fact]
    public void SemicolonsInStringsCommentsAndQuotedNamesDoNotSplit()
    {
        // A comment trailing the statement is left out, as Core's splitter leaves it out.
        const string script = "SELECT 'a;b' \"c;d\" FROM dual -- e;f\n WHERE 1 = 1 /* g;h */;\nSELECT 2 FROM dual";

        Assert.Equal(["SELECT 'a;b' \"c;d\" FROM dual -- e;f\n WHERE 1 = 1", "SELECT 2 FROM dual"], Split(script));
    }

    [Theory]
    [InlineData("SELECT q'[it's; here]' FROM dual")]
    [InlineData("SELECT Q'{a;'b}' FROM dual")]
    [InlineData("SELECT nq'!x;y'!' FROM dual")]
    [InlineData("SELECT q'(a(b);c)' FROM dual")]
    public void AlternativeQuotingIsOneLiteral(string statement)
    {
        Assert.Equal([statement, "SELECT 2 FROM dual"], Split(statement + ";\nSELECT 2 FROM dual;"));
    }

    [Fact]
    public void BlockWithoutSlashRunsToTheEnd()
    {
        Assert.Equal(["BEGIN NULL; END;\nSELECT 1 FROM dual;"], Split("BEGIN NULL; END;\nSELECT 1 FROM dual;"));
    }

    [Fact]
    public void RangesPointBackIntoTheText()
    {
        const string script = "  SELECT 1 FROM dual;\n\nBEGIN NULL; END;\n/\n";

        var statements = OracleScript.Split(script);

        Assert.Equal(2, statements.Length);
        foreach (var statement in statements)
        {
            Assert.Equal(statement.Text, script.Substring(statement.Start, statement.Length));
        }

        Assert.Equal(2, statements[0].Start);
    }

    [Theory]
    [InlineData("")]
    [InlineData("  \n ")]
    [InlineData(";;")]
    [InlineData("/\n/")]
    [InlineData("-- just a comment\n")]
    public void NothingToRunGivesNoStatements(string script)
    {
        Assert.Empty(OracleScript.Split(script));
    }

    [Fact]
    public void LeadingCommentsStayOutOfTheStatement()
    {
        Assert.Equal(["BEGIN NULL; END;"], Split("-- run me\n/* first */ BEGIN NULL; END;\n/"));
    }

    [Fact]
    public void CrLfLineEndsAreRecognised()
    {
        Assert.Equal(["BEGIN NULL; END;", "SELECT 1 FROM dual"], Split("BEGIN NULL; END;\r\n/\r\nSELECT 1 FROM dual;\r\n"));
    }
}
