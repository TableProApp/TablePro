namespace TablePro.Core.Sql.Analysis;

/// <summary>Where go to definition leads.</summary>
public abstract record SqlDefinition;

/// <summary>A name declared in the text itself: a table alias or a common table expression.</summary>
public sealed record SqlTextDefinition(int Start, int Length) : SqlDefinition
{
    public SqlTextRange Range => new(Start, Length);
}

/// <summary>A table or view of the connection, which the workspace opens; <see cref="Column"/> is set when a column led here.</summary>
public sealed record SqlCatalogDefinition(string? Schema, string Table, bool IsView, string? Column = null) : SqlDefinition
{
    /// <summary>
    /// Whether a sidebar object is the one meant. The name compares without case, as the catalog lookup does, and a
    /// definition without a schema matches the object in any schema, since the text named it unqualified.
    /// </summary>
    public bool Matches(string? schema, string name) =>
        string.Equals(name, Table, StringComparison.OrdinalIgnoreCase)
        && (Schema is null || string.Equals(schema, Schema, StringComparison.OrdinalIgnoreCase));
}

public enum SqlSymbolKind
{
    Table,
    View,
    CommonTableExpression,

    /// <summary>The alias of a table, view, subquery or table function.</summary>
    Alias,

    /// <summary>A subquery in FROM, named by the alias after it.</summary>
    Subquery,

    TableFunction,
    Column,
}

/// <summary>A name in the text and what it stands for, as hover and go to definition describe it.</summary>
/// <param name="Kind">What the name is.</param>
/// <param name="Range">Where the name is in the text.</param>
/// <param name="Name">The name as written, without quotes.</param>
/// <param name="Definition">Where go to definition leads, or null when nowhere.</param>
/// <param name="Table">For an alias or a column, the table it belongs to.</param>
/// <param name="Schema">The schema the text qualified the table with, if any.</param>
/// <param name="DataType">For a column, its type from the catalog.</param>
/// <param name="Columns">For a table or an alias of one, its columns when the catalog has loaded them.</param>
/// <param name="TargetKind">For an alias, the kind of what it names.</param>
public sealed record SqlSymbol(
    SqlSymbolKind Kind,
    SqlTextRange Range,
    string Name,
    SqlDefinition? Definition,
    string? Table = null,
    string? Schema = null,
    string? DataType = null,
    IReadOnlyList<(string Name, string Type)>? Columns = null,
    SqlSymbolKind? TargetKind = null);

/// <summary>What the editor shows when the pointer rests on a range: its diagnostics and what the name there means.</summary>
public sealed record SqlHover(SqlTextRange Range, IReadOnlyList<SqlDiagnostic> Diagnostics, SqlSymbol? Symbol, string? Title, string? Detail);
