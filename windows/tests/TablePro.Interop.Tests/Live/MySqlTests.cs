namespace TablePro.Interop.Tests.Live;

public sealed class MySqlTests : SqlEngineTests
{
    private const string Database = "tablepro";

    protected override string CorpusFile => "mysql";

    protected override string? CorpusFlavour => "mysql";

    protected override Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("MYSQL");
        return ConnectAsync(
            core,
            new SavedConnection(null, "MySQL", "mysql", LiveServer.Host, server.Port, Database, server.UserName, new TlsSettings(TlsMode.Require)),
            server.Secrets,
            cancellationToken);
    }

    protected override TableName Table(string name) => new(Database, name);

    protected override string Qualified(string name) => $"`{Database}`.`{name}`";

    protected override string CorpusTableSql(string table) => $"CREATE TABLE {table} (id integer PRIMARY KEY, label text NOT NULL)";

    protected override string PeopleTableSql(string table) =>
        $"CREATE TABLE {table} (id integer PRIMARY KEY, name varchar(100) NOT NULL, note text)";
}
