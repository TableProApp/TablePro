using TablePro.Core.Connections;
using TablePro.Core.Sql;

namespace TablePro.Storage.History;

/// <summary>What ran a statement. Stored as text, with the same values as the macOS app's history.</summary>
public enum QueryHistorySource
{
    Editor,
    Explain,
    TableBrowse,
    RowEdit,
    StructureDdl,
    Import,
    Mcp,
}

public enum QueryHistoryOutcome
{
    Any,
    Succeeded,
    Failed,
}

/// <summary>One executed statement.</summary>
public sealed record QueryHistoryEntry
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Query { get; init; }
    public required Guid ConnectionId { get; init; }
    public string? DatabaseName { get; init; }
    public required DatabaseEngine Engine { get; init; }
    public string? SchemaName { get; init; }
    public StatementKind StatementKind { get; init; } = StatementKind.Unknown;
    public QueryHistorySource Source { get; init; } = QueryHistorySource.Editor;
    public DateTimeOffset ExecutedAt { get; init; } = DateTimeOffset.UtcNow;
    public TimeSpan Elapsed { get; init; }

    /// <summary>Rows returned or affected; -1 when the driver could not tell.</summary>
    public long RowCount { get; init; } = -1;

    public bool Success { get; init; } = true;
    public string? ErrorMessage { get; init; }

    /// <summary>Builds an entry with <see cref="StatementKind"/> read from the SQL by the engine's own lexer rules.</summary>
    public static QueryHistoryEntry Create(
        string query,
        Guid connectionId,
        DatabaseEngine engine,
        TimeSpan elapsed,
        long rowCount,
        string? errorMessage = null,
        string? databaseName = null,
        string? schemaName = null,
        QueryHistorySource source = QueryHistorySource.Editor,
        DateTimeOffset? executedAt = null)
    {
        ArgumentNullException.ThrowIfNull(query);
        return new QueryHistoryEntry
        {
            Query = query,
            ConnectionId = connectionId,
            Engine = engine,
            DatabaseName = databaseName,
            SchemaName = schemaName,
            StatementKind = StatementClassifier.Classify(query, SqlDialects.For(engine)),
            Source = source,
            ExecutedAt = executedAt ?? DateTimeOffset.UtcNow,
            Elapsed = elapsed,
            RowCount = rowCount,
            Success = errorMessage is null,
            ErrorMessage = errorMessage,
        };
    }

    /// <summary>The query on one line, cut to what a history row shows.</summary>
    public string SingleLinePreview
    {
        get
        {
            var collapsed = string.Join(' ', Query.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
            return collapsed.Length <= 160 ? collapsed : string.Concat(collapsed.AsSpan(0, 160), "…");
        }
    }
}

/// <summary>Which entries a history search returns. Every criterion left null matches everything.</summary>
public sealed record QueryHistoryFilter
{
    public Guid? ConnectionId { get; init; }

    /// <summary>Words the query must contain. Each word also matches as a prefix, so partial typing finds results.</summary>
    public string? SearchText { get; init; }

    public QueryHistoryOutcome Outcome { get; init; } = QueryHistoryOutcome.Any;
    public DateTimeOffset? Since { get; init; }
    public DateTimeOffset? Until { get; init; }

    /// <summary>Null includes every source.</summary>
    public IReadOnlySet<QueryHistorySource>? Sources { get; init; }
}

/// <summary>Where the next page starts: the last entry of the previous one, in newest-first order.</summary>
public sealed record QueryHistoryCursor(DateTimeOffset ExecutedAt, Guid Id);

public sealed record QueryHistoryPage(IReadOnlyList<QueryHistoryEntry> Entries, QueryHistoryCursor? NextCursor)
{
    public static QueryHistoryPage Empty { get; } = new([], null);
}
