using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Ai.Prompts;

/// <summary>
/// What a prompt says about the connection: its engine, where the user is, and the structure of the tables in play.
/// It is read from the catalog only; no row is ever part of it.
/// </summary>
public sealed record SchemaContext
{
    public static readonly SchemaContext Empty = new();

    /// <summary>The engine as the user knows it, such as <c>PostgreSQL</c>.</summary>
    public string EngineName { get; init; } = string.Empty;

    public string? Database { get; init; }

    public string? DefaultSchema { get; init; }

    /// <summary>The tables whose structure goes with the request, most relevant first: the budget drops from the end.</summary>
    public IReadOnlyList<TableStructure> Tables { get; init; } = [];

    /// <summary>Row estimates by table, from the sidebar's object list, so a review can tell a big table from a small one.</summary>
    public IReadOnlyDictionary<ObjectName, long> RowEstimates { get; init; } = new Dictionary<ObjectName, long>();

    /// <summary>Approximate tokens the rendered structure may take. Four characters count as one token.</summary>
    public int TokenBudget { get; init; } = SchemaContextBuilder.DefaultTokenBudget;

    public static SchemaContext For(IDatabaseSession session, IReadOnlyList<TableStructure> tables)
    {
        ArgumentNullException.ThrowIfNull(session);
        return new()
        {
            EngineName = session.Profile.Descriptor.DisplayName,
            Database = session.CurrentDatabase ?? session.Profile.Database,
            DefaultSchema = session.DefaultSchema,
            Tables = tables,
        };
    }

    public static SchemaContext For(ConnectionProfile profile, IReadOnlyList<TableStructure> tables)
    {
        ArgumentNullException.ThrowIfNull(profile);
        return new()
        {
            EngineName = profile.Descriptor.DisplayName,
            Database = profile.Database,
            Tables = tables,
        };
    }
}
