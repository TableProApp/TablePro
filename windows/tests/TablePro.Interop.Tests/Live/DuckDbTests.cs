namespace TablePro.Interop.Tests.Live;

// In process, so it runs wherever the tests do.
public sealed class DuckDbTests : SqlEngineTests
{
    protected override string CorpusFile => "duckdb";

    protected override Task<DatabaseSession> OpenAsync(TableProCore core, string directory, CancellationToken cancellationToken) =>
        core.OpenFileAsync(new FileOpenOptions(Path.Combine(directory, "live.duckdb"), "duckdb", Create: true), cancellationToken);

    protected override TableName Table(string name) => new("main", name);

    protected override string Qualified(string name) => $"\"{name}\"";

    protected override string CorpusTableSql(string table) => $"CREATE TABLE {table} (id integer PRIMARY KEY, label text NOT NULL)";

    protected override string PeopleTableSql(string table) =>
        $"CREATE TABLE {table} (id integer PRIMARY KEY, name text NOT NULL, note text)";
}
