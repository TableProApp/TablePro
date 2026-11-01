namespace TablePro.Core.Sql.Analysis;

public enum SqlTableReferenceKind
{
    /// <summary>A table or view, by name.</summary>
    Table,

    /// <summary>A name a WITH clause of the statement defines.</summary>
    CommonTableExpression,

    /// <summary>A parenthesized SELECT in FROM, named only by its alias.</summary>
    Subquery,

    /// <summary>A function in FROM, such as <c>generate_series(1, 10)</c>.</summary>
    Function,
}

/// <summary>A table a statement reads or writes, from FROM, JOIN, UPDATE, INTO, USING or APPLY.</summary>
public sealed class SqlTableReference
{
    internal SqlTableReference(SqlTableReferenceKind kind, SqlTextRange nameRange, string? schema, string name, int scope)
    {
        Kind = kind;
        NameRange = nameRange;
        Schema = schema;
        Name = name;
        Scope = scope;
    }

    public SqlTableReferenceKind Kind { get; }

    /// <summary>The table's own name in the text; for a subquery, its opening parenthesis.</summary>
    public SqlTextRange NameRange { get; }

    /// <summary>The schema the text qualified the name with, if any.</summary>
    public string? Schema { get; }

    /// <summary>The name without quotes; empty for a subquery.</summary>
    public string Name { get; }

    public string? Alias { get; internal set; }

    public SqlTextRange? AliasRange { get; internal set; }

    /// <summary>For a <see cref="SqlTableReferenceKind.CommonTableExpression"/> reference, the definition it reads.</summary>
    public SqlCommonTableExpression? CommonTableExpression { get; internal init; }

    /// <summary>The query level that declares it: the statement's own, or a subquery's.</summary>
    internal int Scope { get; }

    /// <summary>What a column qualifier must say to mean this table: the alias if there is one, otherwise the name.</summary>
    public string ExposedName => Alias ?? Name;
}

/// <summary>A name a WITH clause defines.</summary>
public sealed class SqlCommonTableExpression
{
    internal SqlCommonTableExpression(SqlTextRange nameRange, string name, int scope)
    {
        NameRange = nameRange;
        Name = name;
        Scope = scope;
    }

    public SqlTextRange NameRange { get; }

    public string Name { get; }

    /// <summary>The query level whose WITH defines it; it is visible there and in every subquery inside.</summary>
    internal int Scope { get; }
}

/// <summary><c>qualifier.column</c>, <c>schema.table.column</c> or <c>qualifier.*</c> outside a table position.</summary>
public sealed record SqlQualifiedReference(SqlTextRange QualifierRange, string Qualifier, string? Schema, SqlTextRange? ColumnRange, string? Column, int Scope);

/// <summary>An unqualified name outside a table position, which may be a column of one of the statement's tables.</summary>
public readonly record struct SqlNameOccurrence(SqlTextRange Range, string Name, int Scope);

/// <summary>A query level: the statement itself or a parenthesized subquery, nested by <see cref="Parent"/>.</summary>
internal record struct SqlScope(int Parent, int Start, int End);

/// <summary>
/// What one statement names: its tables and their aliases, its common table expressions, and its qualified and plain
/// names, each with the query level it belongs to so a subquery's alias resolves before the outer query's.
/// </summary>
public sealed class SqlStatementModel
{
    private readonly SqlScope[] _scopes;

    internal SqlStatementModel(
        SqlTextRange range,
        string? verb,
        bool isDataStatement,
        bool changesSchemaContext,
        SqlScope[] scopes,
        SqlTableReference[] tables,
        SqlCommonTableExpression[] commonTableExpressions,
        SqlQualifiedReference[] qualifiedReferences,
        SqlNameOccurrence[] names,
        string[] createdNames)
    {
        Range = range;
        Verb = verb;
        IsDataStatement = isDataStatement;
        ChangesSchemaContext = changesSchemaContext;
        _scopes = scopes;
        Tables = tables;
        CommonTableExpressions = commonTableExpressions;
        QualifiedReferences = qualifiedReferences;
        Names = names;
        CreatedNames = createdNames;
    }

    public SqlTextRange Range { get; }

    /// <summary>The statement's main verb in upper case (SELECT, INSERT, UPDATE, DELETE, MERGE, ...), or null.</summary>
    public string? Verb { get; }

    /// <summary>Whether the statement queries or changes rows, the only statements whose names are checked against the catalog.</summary>
    public bool IsDataStatement { get; }

    /// <summary>A <c>USE</c> or <c>SET search_path</c>, after which the catalog no longer describes what names resolve to.</summary>
    public bool ChangesSchemaContext { get; }

    public IReadOnlyList<SqlTableReference> Tables { get; }

    public IReadOnlyList<SqlCommonTableExpression> CommonTableExpressions { get; }

    public IReadOnlyList<SqlQualifiedReference> QualifiedReferences { get; }

    public IReadOnlyList<SqlNameOccurrence> Names { get; }

    /// <summary>Tables and views the statement creates, which later statements may name although the catalog does not list them.</summary>
    public IReadOnlyList<string> CreatedNames { get; }

    /// <summary>The innermost query level holding the offset.</summary>
    internal int ScopeAt(int offset)
    {
        var best = 0;
        for (var i = 1; i < _scopes.Length; i++)
        {
            var scope = _scopes[i];
            if (offset >= scope.Start && offset < scope.End && scope.Start >= _scopes[best].Start)
            {
                best = i;
            }
        }

        return best;
    }

    internal int ParentOf(int scope) => _scopes[scope].Parent;

    internal bool IsVisibleFrom(int declaredIn, int scope)
    {
        for (var s = scope; s >= 0; s = _scopes[s].Parent)
        {
            if (s == declaredIn)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// The table a qualifier means, looking from the innermost query level outwards as SQL does. A qualifier no level
    /// declares still matches a table anywhere in the statement, so an odd construct reads as known rather than wrong.
    /// </summary>
    public SqlTableReference? ResolveQualifier(string qualifier, int scope)
    {
        for (var s = scope; s >= 0; s = _scopes[s].Parent)
        {
            foreach (var table in Tables)
            {
                if (table.Scope == s && string.Equals(table.ExposedName, qualifier, StringComparison.OrdinalIgnoreCase))
                {
                    return table;
                }
            }
        }

        foreach (var table in Tables)
        {
            if (string.Equals(table.ExposedName, qualifier, StringComparison.OrdinalIgnoreCase))
            {
                return table;
            }
        }

        return null;
    }

    /// <summary>The common table expression a name means from a query level, or null.</summary>
    internal SqlCommonTableExpression? FindCommonTableExpression(string name, int scope)
    {
        foreach (var cte in CommonTableExpressions)
        {
            if (string.Equals(cte.Name, name, StringComparison.OrdinalIgnoreCase) && IsVisibleFrom(cte.Scope, scope))
            {
                return cte;
            }
        }

        return null;
    }

    internal bool DefinesCommonTableExpression(string name)
    {
        foreach (var cte in CommonTableExpressions)
        {
            if (string.Equals(cte.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
