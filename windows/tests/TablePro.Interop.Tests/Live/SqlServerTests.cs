namespace TablePro.Interop.Tests.Live;

public sealed class SqlServerTests : SqlEngineTests
{
    private const string Database = "tablepro";

    protected override string CorpusFile => "mssql";

    [Fact]
    public async Task AWindowsLoginSignsInAsTheAccountRunningTheTests()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var server = LiveServer.Require("MSSQL");
        await using var session = await ConnectAsync(
            Core,
            Connection(server) with { UserName = string.Empty, IntegratedAuth = true },
            ConnectionSecrets.None,
            cancellationToken);
        await using var editor = await session.OpenEditorAsync(cancellationToken);
        using var run = editor.Run("SELECT SUSER_SNAME()", cancellationToken: cancellationToken);

        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0);
        Assert.NotNull(set);
        Assert.Equal($@"{Environment.UserDomainName}\{Environment.UserName}", set.GetCellText(0, 0), ignoreCase: true);
    }

    protected override async Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("MSSQL");
        await using (var master = await ConnectAsync(core, Connection(server) with { Database = "master" }, server.Secrets, cancellationToken))
        {
            await using var editor = await master.OpenEditorAsync(cancellationToken);
            await ExecuteAsync(editor, $"IF DB_ID(N'{Database}') IS NULL CREATE DATABASE {Database}", cancellationToken);
        }

        return await ConnectAsync(core, Connection(server), server.Secrets, cancellationToken);
    }

    protected override TableName Table(string name) => new("dbo", name);

    protected override string Qualified(string name) => $"[dbo].[{name}]";

    protected override string Text(string value) => "N" + base.Text(value);

    protected override string CorpusTableSql(string table) => $"CREATE TABLE {table} (id int PRIMARY KEY, label nvarchar(200) NOT NULL)";

    protected override string PeopleTableSql(string table) =>
        $"CREATE TABLE {table} (id int PRIMARY KEY, name nvarchar(100) NOT NULL, note nvarchar(max))";

    // core/crates/drivers/mssql/tests/windows/sql-server.ps1 gives the server a self-signed certificate for localhost.
    private static SavedConnection Connection(LiveServer server) => new(
        null,
        "SQL Server",
        "mssql",
        "localhost",
        server.Port,
        Database,
        server.UserName,
        new TlsSettings(TlsMode.VerifyFull, CaFile: Environment.GetEnvironmentVariable("TABLEPRO_TEST_MSSQL_WINDOWS_CA")));
}
