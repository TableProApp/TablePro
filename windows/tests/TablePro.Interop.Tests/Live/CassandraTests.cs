namespace TablePro.Interop.Tests.Live;

public sealed class CassandraTests : SqlEngineTests
{
    private const string Keyspace = "tablepro";

    protected override string CorpusFile => "cassandra";

    protected override async Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("CASSANDRA");
        await using (var start = await ConnectAsync(core, Connection(server, "system"), server.Secrets, cancellationToken))
        {
            await using var editor = await start.OpenEditorAsync(cancellationToken);
            await ExecuteAsync(
                editor,
                $"CREATE KEYSPACE IF NOT EXISTS {Keyspace} WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': 1}}",
                cancellationToken);
        }

        return await ConnectAsync(core, Connection(server, Keyspace), server.Secrets, cancellationToken);
    }

    protected override TableName Table(string name) => new(Keyspace, name);

    protected override string Qualified(string name) => $"{Keyspace}.{name}";

    protected override string CorpusTableSql(string table) => $"CREATE TABLE {table} (id int PRIMARY KEY, label text)";

    protected override string PeopleTableSql(string table) => $"CREATE TABLE {table} (id int PRIMARY KEY, name text, note text)";

    private static SavedConnection Connection(LiveServer server, string keyspace) =>
        new(null, "Cassandra", "cassandra", LiveServer.Host, server.Port, keyspace, server.UserName, TlsSettings.Disabled);
}
