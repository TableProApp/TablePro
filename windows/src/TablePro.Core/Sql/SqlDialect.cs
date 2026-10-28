using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Schema;

namespace TablePro.Core.Sql;

/// <summary>
/// Everything that differs in how an engine spells SQL: quoting, literals, paging and how a script splits.
/// Dialects are stateless singletons; the drivers and the editor share them.
/// </summary>
public abstract class SqlDialect
{
    public abstract string Name { get; }

    public abstract SqlLexerFeatures LexerFeatures { get; }

    /// <summary>
    /// False for a command language (Redis, mongosh, etcdctl and the like): the editor then offers no SQL formatter
    /// and the workspace never asks the dialect's SQL builders for a statement.
    /// </summary>
    public virtual bool IsSql => true;

    /// <summary>What a line comment starts with, for the editor's comment toggle.</summary>
    public virtual string LineComment => "--";

    /// <summary>Splits a script into the units the engine runs one at a time.</summary>
    public virtual ImmutableArray<SqlStatement> Split(string text) => SqlScript.SplitSql(text, this);

    /// <summary>What a statement does, for Safe Mode and history.</summary>
    public virtual StatementKind Classify(string statement) => StatementClassifier.ClassifySql(statement, this);

    /// <summary>Whether the editor colors a word as a keyword or command.</summary>
    public virtual bool IsKeyword(ReadOnlySpan<char> word) => SqlKeywords.IsKeyword(word);

    /// <summary>The words completion offers beside the schema's names.</summary>
    public virtual IEnumerable<string> CompletionKeywords => SqlKeywords.All;

    /// <summary>Whether the formatter can lay this language out.</summary>
    public virtual bool SupportsFormatting => IsSql;

    /// <summary>The line that ends a batch, such as SQL Server's <c>GO</c>. Null splits at <c>;</c>.</summary>
    public virtual string? BatchSeparator => null;

    /// <summary>MySQL clients honour <c>DELIMITER</c> lines to run stored programs.</summary>
    public virtual bool SupportsDelimiterDirective => false;

    /// <summary>SQLite keeps a <c>CREATE TRIGGER ... BEGIN ... END</c> body whole across its <c>;</c>.</summary>
    public virtual bool KeepsTriggerBodies => false;

    public virtual char IdentifierOpen => '"';

    public virtual char IdentifierClose => '"';

    public virtual string ParameterName(int index) => string.Create(CultureInfo.InvariantCulture, $"@p{index}");

    /// <summary>GoogleSQL and SurrealQL escape the closing quote inside a name with a backslash instead of doubling it.</summary>
    protected virtual bool BackslashEscapesIdentifiers => false;

    public string QuoteIdentifier(string identifier)
    {
        var close = IdentifierClose.ToString();
        var escaped = BackslashEscapesIdentifiers
            ? identifier.Replace("\\", "\\\\", StringComparison.Ordinal).Replace(close, "\\" + close, StringComparison.Ordinal)
            : identifier.Replace(close, close + close, StringComparison.Ordinal);
        return string.Concat(IdentifierOpen.ToString(), escaped, close);
    }

    public string Qualify(ObjectName name) =>
        string.IsNullOrEmpty(name.Schema) ? QuoteIdentifier(name.Name) : $"{QuoteIdentifier(name.Schema)}.{QuoteIdentifier(name.Name)}";

    public virtual string StringLiteral(string value) => string.Concat("'", value.Replace("'", "''", StringComparison.Ordinal), "'");

    public virtual string BinaryLiteral(ReadOnlySpan<byte> value) => string.Concat("X'", Convert.ToHexString(value), "'");

    public virtual string BooleanLiteral(bool value) => value ? "TRUE" : "FALSE";

    /// <summary>Spells a value as a literal for generated scripts such as an INSERT export.</summary>
    public string Literal(object? value) => value switch
    {
        null or DBNull => "NULL",
        bool b => BooleanLiteral(b),
        byte[] bytes => BinaryLiteral(bytes),
        string s => StringLiteral(s),

        // char is a primitive IFormattable, so without this arm it would be written unquoted.
        char c => StringLiteral(c.ToString()),
        DateTime dt => StringLiteral(dt.ToString(dt.TimeOfDay == TimeSpan.Zero ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture)),
        DateTimeOffset dto => StringLiteral(dto.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFFzzz", CultureInfo.InvariantCulture)),
        DateOnly d => StringLiteral(d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)),
        TimeOnly t => StringLiteral(t.ToString("HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture)),
        TimeSpan ts => StringLiteral(ts.ToString("c", CultureInfo.InvariantCulture)),
        Guid g => StringLiteral(g.ToString()),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        IFormattable number when value.GetType().IsPrimitive || value is decimal => number.ToString(null, CultureInfo.InvariantCulture),
        _ => StringLiteral(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty),
    };

    /// <summary>Appends the paging clause after an ORDER BY (or its absence).</summary>
    public virtual void AppendPaging(StringBuilder sql, int offset, int limit, bool hasOrderBy) =>
        sql.Append(CultureInfo.InvariantCulture, $" LIMIT {limit} OFFSET {offset}");

    /// <summary>Builds the statement a table tab runs to show one page.</summary>
    public SqlCommandSpec BuildBrowse(BrowseRequest request)
    {
        var sql = new StringBuilder("SELECT * FROM ").Append(Qualify(request.Table));
        var parameters = new List<KeyValuePair<string, object?>>();
        AppendWhere(sql, request.Filter, parameters);
        var hasOrderBy = AppendOrderBy(sql, request.Sort);
        AppendPaging(sql, request.Offset, request.Limit, hasOrderBy);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    public SqlCommandSpec BuildCount(ObjectName table, BrowseFilter filter)
    {
        var sql = new StringBuilder("SELECT COUNT(*) FROM ").Append(Qualify(table));
        var parameters = new List<KeyValuePair<string, object?>>();
        AppendWhere(sql, filter, parameters);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private void AppendWhere(StringBuilder sql, BrowseFilter filter, List<KeyValuePair<string, object?>> parameters)
    {
        var clauses = new List<string>(filter.Rules.Count + 1);
        foreach (var rule in filter.Rules.Where(r => r.Enabled))
        {
            clauses.Add(FilterSql.Render(this, rule, filter.SearchColumns, parameters));
        }

        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            clauses.Add($"({filter.RawWhere})");
        }

        if (clauses.Count > 0)
        {
            sql.Append(" WHERE ").AppendJoin(filter.MatchAll ? " AND " : " OR ", clauses);
        }
    }

    private bool AppendOrderBy(StringBuilder sql, IReadOnlyList<SortColumn> sort)
    {
        if (sort.Count == 0)
        {
            return false;
        }

        sql.Append(" ORDER BY ");
        for (var i = 0; i < sort.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(", ");
            }

            sql.Append(QuoteIdentifier(sort[i].Column)).Append(sort[i].Descending ? " DESC" : " ASC");
        }

        return true;
    }

    /// <summary>The statements that make the server report a plan, run in order on one connection.</summary>
    public virtual IReadOnlyList<string> Explain(string statement) => ["EXPLAIN " + statement];

    /// <summary>The statements for a plan the app can draw, with ANALYZE when asked; null when the engine has no such form.</summary>
    public virtual Plans.PlanRequest? PlanStatements(string statement, bool analyze) => null;

    /// <summary>A case-insensitive LIKE, which only PostgreSQL and DuckDB spell differently.</summary>
    public virtual string CaseInsensitiveLike => "LIKE";

    /// <summary>The characters a LIKE pattern treats as wildcards, which a literal search must escape.</summary>
    public virtual string LikeWildcards => "%_";

    /// <summary>Casts a column to text so a LIKE works on any type.</summary>
    public virtual string CastToText(string quotedColumn) => $"CAST({quotedColumn} AS VARCHAR(4000))";
}

/// <summary>Command text and its parameters, ready for any ADO.NET provider.</summary>
public sealed record SqlCommandSpec(string Text, IReadOnlyList<KeyValuePair<string, object?>> Parameters);
