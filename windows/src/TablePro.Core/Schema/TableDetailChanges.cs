using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Core.Schema;

/// <summary>A CHECK constraint as the structure editor describes it; the expression is SQL the user typed.</summary>
public sealed record CheckConstraintDefinition(string Name, string Expression)
{
    public bool IsComplete => !string.IsNullOrWhiteSpace(Name) && !string.IsNullOrWhiteSpace(Expression);
}

/// <summary>A new partition and its bound, spelled in the engine's own syntax, such as <c>VALUES LESS THAN (2025)</c>.</summary>
public sealed record PartitionDefinition(string Name, string Bound);

/// <summary>One option the editor changed. A null or empty <see cref="After"/> asks for the engine's default back.</summary>
public sealed record TableOptionChange(string Name, string? Before, string? After)
{
    public bool Clears => string.IsNullOrWhiteSpace(After);

    /// <summary>
    /// The options whose edited value differs from the current one. Values are compared trimmed, and an empty value
    /// equals a missing one, so tabbing through an empty field is not a change.
    /// </summary>
    public static IReadOnlyList<TableOptionChange> Diff(IReadOnlyList<TableOption> current, IReadOnlyDictionary<string, string?> edited)
    {
        var changes = new List<TableOptionChange>();
        foreach (var (name, value) in edited)
        {
            string? before = null;
            foreach (var option in current)
            {
                if (string.Equals(option.Name, name, StringComparison.OrdinalIgnoreCase))
                {
                    before = option.Value;
                    break;
                }
            }

            var after = Normalize(value);
            if (!string.Equals(Normalize(before), after, StringComparison.Ordinal))
            {
                changes.Add(new TableOptionChange(name, before, after));
            }
        }

        return changes;
    }

    private static string? Normalize(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

public sealed record AddCheckConstraint(CheckConstraintDefinition Constraint) : SchemaChange;

public sealed record DropCheckConstraint(string Name) : SchemaChange;

/// <summary>
/// A renamed or rewritten check. A rename alone is one statement on the engines that have one; a new expression drops
/// and re-adds the constraint, which re-checks every row.
/// </summary>
public sealed record AlterCheckConstraint(CheckConstraintDefinition Before, CheckConstraintDefinition After) : SchemaChange
{
    public bool IsRenameOnly =>
        !string.Equals(Before.Name, After.Name, StringComparison.Ordinal)
        && string.Equals(Before.Expression.Trim(), After.Expression.Trim(), StringComparison.Ordinal);
}

public sealed record AddPartition(PartitionDefinition Partition) : SchemaChange;

/// <summary>Drops a partition and its rows. It carries the whole partition because a PostgreSQL one is a table in its own schema.</summary>
public sealed record DropPartition(PartitionInfo Partition) : SchemaChange;

public sealed record TruncatePartition(PartitionInfo Partition) : SchemaChange;

public sealed record SetTableOptions(IReadOnlyList<TableOptionChange> Changes) : SchemaChange;

/// <summary>Text helpers for the catalog's spelling of constraints and table bodies, shared by the drivers.</summary>
public static class ConstraintText
{
    /// <summary>
    /// Removes parentheses that wrap the whole expression, as PostgreSQL's <c>CHECK ((a &gt; 0))</c> and SQL Server's
    /// <c>([a]&gt;(0))</c> add. <c>(a &gt; 0) AND (b &gt; 0)</c> keeps both pairs, since neither encloses the whole.
    /// </summary>
    public static string StripEnclosingParentheses(string expression)
    {
        var current = expression.Trim();
        while (current.Length >= 2 && current[0] == '(' && current[^1] == ')' && ClosesAtEnd(current))
        {
            current = current[1..^1].Trim();
        }

        return current;
    }

    /// <summary>
    /// The expression of a <c>pg_get_constraintdef</c>-style clause: <c>CHECK ((a &lt; 1000)) NOT VALID</c> becomes
    /// <c>a &lt; 1000</c>. Text that does not start with CHECK is returned trimmed.
    /// </summary>
    public static string CheckClauseExpression(string definition)
    {
        var text = definition.Trim();
        foreach (var suffix in (ReadOnlySpan<string>)["NOT VALID", "NO INHERIT", "NOT ENFORCED", "ENFORCED"])
        {
            if (text.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                text = text[..^suffix.Length].TrimEnd();
            }
        }

        if (!text.StartsWith("CHECK", StringComparison.OrdinalIgnoreCase))
        {
            return text;
        }

        return StripEnclosingParentheses(text["CHECK".Length..]);
    }

    /// <summary>
    /// The comma-separated entries inside the first parentheses of a CREATE TABLE, at the top level only, trimmed. Empty
    /// when the statement has no column list.
    /// </summary>
    public static IReadOnlyList<string> CreateTableEntries(string sql, SqlLexerFeatures features)
    {
        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, features);
        var entries = new List<string>();
        var depth = 0;
        var start = -1;
        while (lexer.TryRead(out var token))
        {
            if (depth == 0)
            {
                if (token.Kind == SqlTokenKind.OpenParen)
                {
                    depth = 1;
                    start = token.End;
                }

                continue;
            }

            switch (token.Kind)
            {
                case SqlTokenKind.OpenParen:
                    depth++;
                    break;
                case SqlTokenKind.CloseParen when --depth == 0:
                    Add(entries, sql, start, token.Start);
                    return entries;
                case SqlTokenKind.Comma when depth == 1:
                    Add(entries, sql, start, token.Start);
                    start = token.End;
                    break;
            }
        }

        return [];
    }

    /// <summary>
    /// Reads <c>CONSTRAINT name CHECK expression</c> or a bare <c>CHECK (expression)</c> from one table entry. The name
    /// may be quoted with any of the dialect's identifier quotes; a bare check comes back with a null name.
    /// </summary>
    public static (string? Name, string Expression)? ParseCheckEntry(string entry, SqlLexerFeatures features)
    {
        var span = entry.AsSpan();
        var lexer = new SqlLexer(span, features);
        string? name = null;
        var state = 0;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            var text = token.Slice(span);
            switch (state)
            {
                case 0 when token.Kind == SqlTokenKind.Word && text.Equals("CONSTRAINT", StringComparison.OrdinalIgnoreCase):
                    state = 1;
                    break;
                case 0 or 2 when token.Kind == SqlTokenKind.Word && text.Equals("CHECK", StringComparison.OrdinalIgnoreCase):
                    var expression = entry[token.End..].Trim();
                    return expression.Length == 0 ? null : (name, StripEnclosingParentheses(expression));
                case 1 when token.Kind is SqlTokenKind.Word or SqlTokenKind.QuotedIdentifier:
                    name = token.Kind == SqlTokenKind.QuotedIdentifier ? Unquote(text) : text.ToString();
                    state = 2;
                    break;
                default:
                    return null;
            }
        }

        return null;
    }

    private static void Add(List<string> entries, string sql, int start, int end)
    {
        var text = sql[start..end].Trim();
        if (text.Length > 0)
        {
            entries.Add(text);
        }
    }

    private static string Unquote(ReadOnlySpan<char> quoted)
    {
        if (quoted.Length < 2)
        {
            return quoted.ToString();
        }

        var close = quoted[^1];
        var body = quoted[1..^1];
        var doubled = string.Concat(close.ToString(), close.ToString());
        return new StringBuilder(body.Length).Append(body).Replace(doubled, close.ToString()).ToString();
    }

    /// <summary>True when the opening parenthesis is the one the last character closes; quoted text does not count.</summary>
    private static bool ClosesAtEnd(string text)
    {
        var depth = 0;
        char? quote = null;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quote is { } open)
            {
                if (c == open)
                {
                    quote = null;
                }

                continue;
            }

            switch (c)
            {
                case '\'' or '"' or '`':
                    quote = c;
                    break;
                case '[':
                    quote = ']';
                    break;
                case '(':
                    depth++;
                    break;
                case ')' when --depth == 0:
                    return i == text.Length - 1;
            }
        }

        return false;
    }
}
