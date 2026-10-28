namespace TablePro.Mcp;

public sealed record McpServerOptions
{
    public const int DefaultPort = 23508;

    public const string DefaultPath = "/mcp";

    /// <summary>Port 0 takes any free port, which tests use.</summary>
    public int Port { get; init; } = DefaultPort;

    public string Path { get; init; } = DefaultPath;

    /// <summary>The version <c>initialize</c> reports in <c>serverInfo</c>.</summary>
    public string ServerVersion { get; init; } = typeof(McpServerOptions).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    /// <summary>A body larger than this is refused before it is read: a statement is at most 100 KB, and nothing else a client sends is big.</summary>
    public int MaxRequestBytes { get; init; } = 1024 * 1024;

    /// <summary>Connections served at once. A client holds one or two; the rest wait until one closes.</summary>
    public int MaxConnections { get; init; } = 32;

    public int AuditCapacity { get; init; } = 500;

    /// <summary>The longest statement <c>execute_query</c> takes, in UTF-8 bytes.</summary>
    public int MaxQueryBytes { get; init; } = 100 * 1024;

    /// <summary>Result sets one answer keeps.</summary>
    public int MaxResultSets { get; init; } = 20;

    /// <summary>Rows one result set keeps, the most a client may ask for.</summary>
    public int MaxRows { get; init; } = 1_000;

    public int DefaultRows { get; init; } = 100;

    /// <summary>The most a client may ask a statement to run for.</summary>
    public int MaxTimeoutSeconds { get; init; } = 300;

    public int DefaultTimeoutSeconds { get; init; } = 30;

    /// <summary>A cell's text beyond this is cut, so one wide column cannot blow up an answer.</summary>
    public int MaxCellChars { get; init; } = 4_096;

    /// <summary>
    /// How long past a statement's timeout the server cancels it itself. The driver's own command timeout should
    /// fire first; this backstop covers a driver that ignores it. Tests shorten it.
    /// </summary>
    internal TimeSpan TimeoutGrace { get; init; } = TimeSpan.FromSeconds(5);
}
