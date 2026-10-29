using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Principals;
using TablePro.Core.Schema;
using TablePro.Drivers.Oracle;
using TablePro.Drivers.Tests.Live;

namespace TablePro.Drivers.Analytics.Tests;

/// <summary>
/// The relational live suite against TABLEPRO_ORACLE_ADMIN, a login that may read V$SESSION and create users, for example
/// <c>host=localhost;port=1521;user=system;password=TablePro-test-1;database=FREEPDB1</c>.
/// </summary>
public sealed class OracleServerTests : RelationalServerTests
{
    protected override string Variable => "TABLEPRO_ORACLE_ADMIN";

    protected override DatabaseEngine Engine => DatabaseEngine.Oracle;

    protected override IDatabaseDriver Driver { get; } = new OracleDriver();

    protected override string IntType => "NUMBER(10)";

    protected override string TextType => "VARCHAR2(100)";

    // Wider than the integer column it replaces: Oracle refuses to narrow the integer digits of a column with rows.
    protected override string DecimalType => "NUMBER(12,2)";

    protected override string TimestampType => "TIMESTAMP";

    // DBMS_SESSION.SLEEP only notices a cancel when it wakes, so the statement is a join Oracle cannot shortcut.
    protected override string SleepStatement => "SELECT COUNT(*) FROM all_objects a, all_objects b WHERE a.object_name || b.object_name = 'x'";

    protected override string ConnectionIdStatement => "SELECT SID || ',' || SERIAL# FROM V$SESSION WHERE SID = SYS_CONTEXT('USERENV', 'SID')";

    protected override string SelectOne => "SELECT 1 FROM DUAL";

    protected override string? BeginStatement => null;

    protected override bool ErrorNamesTheMissingTable => false;

    protected override bool EditorAutoCommits => true;

    protected override bool ServerEnforcesReadOnly => false;

    protected override PrivilegeScope TableScope(IDatabaseSession session, ObjectName table) =>
        PrivilegeScope.ForTable(table.Schema!, null, table.Name);
}
