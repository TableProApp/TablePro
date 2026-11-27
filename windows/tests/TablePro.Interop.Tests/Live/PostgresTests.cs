namespace TablePro.Interop.Tests.Live;

public sealed class PostgresTests : SqlEngineTests
{
    private const string Database = "tablepro";
    private const string Schema = "public";

    protected override string CorpusFile => "postgres";

    protected override Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("POSTGRES");
        return ConnectAsync(
            core,
            new SavedConnection(null, "PostgreSQL", "postgres", LiveServer.Host, server.Port, Database, server.UserName, new TlsSettings(TlsMode.Prefer)),
            server.Secrets,
            cancellationToken);
    }

    protected override TableName Table(string name) => new(Schema, name);

    protected override string Qualified(string name) => $"\"{Schema}\".\"{name}\"";

    protected override string CorpusTableSql(string table) => $"CREATE TABLE {table} (id integer PRIMARY KEY, label text NOT NULL)";

    protected override string PeopleTableSql(string table) =>
        $"CREATE TABLE {table} (id integer PRIMARY KEY, name varchar(100) NOT NULL, note text)";
}
