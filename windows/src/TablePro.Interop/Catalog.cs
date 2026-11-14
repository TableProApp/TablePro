namespace TablePro.Interop;

public enum DataModel
{
    Relational,
    KeyValue,
    Document,
}

// The family the connect dialog lists an engine under, in the order it lists them.
// Where the certificate can be checked against a name other than the host.
public enum ServerNameOverride
{
    AnyRoute,
    SshForwardOnly,
    Unsupported,
}

public enum EngineCategory
{
    Relational,
    Document,
    KeyValue,
    Analytical,
    WideColumn,
}

// FileSuffixes: the suffixes a file engine claims, the one a new file gets first. Empty for a network engine.
public sealed record DatabaseEngine(
    string Id,
    string DisplayName,
    DataModel DataModel,
    int? DefaultPort,
    IReadOnlyList<string> FileSuffixes,
    EngineCategory Category = EngineCategory.Relational)
{
    public IReadOnlyList<TlsMode> SupportedTlsModes { get; init; } = [];

    public TlsMode DefaultTlsMode { get; init; }

    public IReadOnlyList<int> TlsPorts { get; init; } = [];

    public ServerNameOverride ServerNameOverride { get; init; } = ServerNameOverride.Unsupported;

    public bool ShowsServerName(bool overSsh) => ServerNameOverride switch
    {
        ServerNameOverride.AnyRoute => true,
        ServerNameOverride.SshForwardOnly => overSsh,
        _ => false,
    };

    // The core's rule (core/docs/decisions/0014-tls-mode-of-a-new-connection.md).
    public TlsMode NewConnectionTls(int? port) =>
        port is { } number && TlsPorts.Contains(number) ? TlsMode.VerifyFull : DefaultTlsMode;

    public bool SupportsIntegratedAuth { get; init; }

    public bool SupportsClientIdentity { get; init; }
}

public sealed record SchemaEntry(string Name, bool IsDefault, bool IsSystem);

public enum ObjectKind
{
    Table,
    PartitionedTable,
    View,
    MaterializedView,
    ForeignTable,
    Sequence,
    Function,
    Procedure,
    Trigger,
    Dictionary,
    Key,

    // A kind a newer core reports that this build does not name.
    Other,
}

// ParentTable: the table a trigger fires on.
public sealed record ObjectEntry(string? Schema, string Name, ObjectKind Kind, string? ParentTable);

public abstract record ObjectScope
{
    private ObjectScope()
    {
    }

    public static ObjectScope DefaultSchema { get; } = new DefaultSchemaScope();

    public static ObjectScope AllSchemas { get; } = new AllSchemasScope();

    public static ObjectScope Schema(string name) => new NamedSchema(name);

    public sealed record NamedSchema(string Name) : ObjectScope;

    public sealed record DefaultSchemaScope : ObjectScope;

    public sealed record AllSchemasScope : ObjectScope;
}

// No schema means the engine has none, or the default one.
public sealed record TableName(string? Schema, string Name);

// Column is the table's column position, as the grid numbers its columns.
public sealed record ColumnSort(int Column, bool Ascending);

// Past VisibleColumns: the row's address. ViewSql: every row's query, or null. Without CanSeek an offset reads
// through the rows before it, so the next page resumes from where this one stopped (NextPage).
public sealed class TablePageRun : IDisposable
{
    private readonly Native.TablePageRead _page;

    internal TablePageRun(Native.TablePageRead page, QueryRun run)
    {
        _page = page;
        Run = run;
        VisibleColumns = checked((int)page.VisibleColumns());
        CanSeek = page.CanSeek();
        ViewSql = page.ViewSql();
    }

    public QueryRun Run { get; }

    public int VisibleColumns { get; }

    public bool CanSeek { get; }

    public string? ViewSql { get; }

    // Read once the run finished; null for an engine that seeks, or after the last page.
    public PageResume? NextPage() => _page.NextPage() is { } next ? new PageResume(next) : null;

    public void Dispose() => _page.Dispose();
}

// Where a server-paged table's next page starts. Only a read of the same table, sort, filter and page size takes it.
public sealed class PageResume : IDisposable
{
    internal PageResume(Native.PageResume resume)
    {
        Handle = resume;
    }

    internal Native.PageResume Handle { get; }

    public void Dispose() => Handle.Dispose();
}

public enum DatabaseLayout
{
    // A connection reaches one database: a file, or numbered databases of keys.
    OneDatabase,

    // The server's databases are the schemas the catalog lists, so one connection reads every one.
    AsSchemas,

    // Each database holds schemas of its own; a connection's catalog describes the one it opened.
    WithSchemas,
}

public enum FailureCause
{
    Authentication,
    Tls,
    Configuration,
    HostKey,
}

// How a session's connection is doing. A reconnect replaces it on its own; a failed one waits for Reconnect.
public abstract record SessionHealth
{
    private SessionHealth()
    {
    }

    public sealed record Online : SessionHealth;

    public sealed record Reconnecting(int Attempt) : SessionHealth;

    // The server is unreachable; the core checks again on a long timer.
    public sealed record Offline : SessionHealth;

    public sealed record Failed(FailureCause Cause, CoreError? Reason) : SessionHealth;
}

// TypeName: the type as the server spells it, for display.
public sealed record ColumnEntry(
    string Name,
    string TypeName,
    ValueKind ValueKind,
    bool IsNullable,
    bool IsPrimaryKey,
    bool IsAutoIncrement,
    bool IsGenerated,
    string? Comment);
