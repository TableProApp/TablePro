namespace TablePro.Interop.Tests.Live;

public sealed class ClickHouseTests : SqlEngineTests
{
    private const string Database = "tablepro";

    protected override string CorpusFile => "clickhouse";

    protected override async Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken)
    {
        var server = LiveServer.Require("CLICKHOUSE");
        await using (var start = await ConnectAsync(core, Connection(server, "default"), server.Secrets, cancellationToken))
        {
            await using var editor = await start.OpenEditorAsync(cancellationToken);
            await ExecuteAsync(editor, $"CREATE DATABASE IF NOT EXISTS {Database}", cancellationToken);
        }

        return await ConnectAsync(core, Connection(server, Database), server.Secrets, cancellationToken);
    }

    protected override TableName Table(string name) => new(Database, name);

    protected override string Qualified(string name) => $"`{Database}`.`{name}`";

    protected override string CorpusTableSql(string table) =>
        $"CREATE TABLE {table} (id Int32, label String) ENGINE = MergeTree ORDER BY id";

    protected override string PeopleTableSql(string table) =>
        $"CREATE TABLE {table} (id Int32, name String, note Nullable(String)) ENGINE = MergeTree ORDER BY id";

    private static SavedConnection Connection(LiveServer server, string database) =>
        new(null, "ClickHouse", "clickhouse", LiveServer.Host, server.Port, database, server.UserName, TlsSettings.Disabled);
}
