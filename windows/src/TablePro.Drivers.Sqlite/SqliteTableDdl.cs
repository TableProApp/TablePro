using System.Collections.Frozen;
using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Sqlite;

/// <summary>One top-level entry inside the parentheses of a <c>CREATE TABLE</c>, as SQLite stored it.</summary>
internal sealed record SqliteTableEntry(string Text, string? ColumnName)
{
    public bool IsColumn => ColumnName is not null;
}

internal sealed record SqliteCreateTable(IReadOnlyList<SqliteTableEntry> Entries, string Suffix, bool WithoutRowid);

/// <summary>A constraint clause of one column definition, as a range of the definition's text.</summary>
internal readonly record struct SqliteColumnClause(string Kind, string? ConstraintName, int Start, int End);

internal sealed record SqliteColumnParts(string Name, IReadOnlyList<SqliteColumnClause> Clauses);

/// <summary>A foreign key as the stored statement declares it, table level or on a column.</summary>
internal sealed record SqliteDeclaredForeignKey(string? Name, IReadOnlyList<string> Columns, int EntryIndex, SqliteColumnClause? InlineClause);

/// <summary>
/// Reads and rewrites the <c>CREATE TABLE</c> text SQLite keeps in <c>sqlite_master</c>. A rebuild moves the column
/// definitions it does not change as text, which is the only way to keep a <c>CHECK</c>, a <c>COLLATE</c>, a
/// generated column or a <c>DEFAULT 'a, b'</c> that <c>PRAGMA table_info</c> does not report.
/// </summary>
internal static class SqliteTableDdl
{
    private static readonly SqlLexerFeatures Features = SqliteDialect.Instance.LexerFeatures;

    private static readonly FrozenSet<string> TableConstraintKeywords =
        new[] { "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN" }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    private static readonly FrozenSet<string> ClauseStarts =
        new[] { "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE", "REFERENCES", "GENERATED", "AS" }
            .ToFrozenSet(StringComparer.Ordinal);

    /// <summary>
    /// Splits the statement into entries. Null for a virtual table, whose module arguments parse like a column list
    /// and which a rebuild would destroy, and for <c>CREATE TABLE ... AS SELECT</c>, which has no column list.
    /// </summary>
    public static SqliteCreateTable? Parse(string sql)
    {
        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, Features);
        var sawCreate = false;
        var sawTable = false;
        var found = false;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (token.Kind == SqlTokenKind.OpenParen)
            {
                found = sawTable;
                break;
            }

            if (token.Kind != SqlTokenKind.Word)
            {
                continue;
            }

            var word = token.Slice(span);
            if (!sawCreate)
            {
                if (!word.Equals("CREATE", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }

                sawCreate = true;
            }
            else if (!sawTable)
            {
                if (word.Equals("TABLE", StringComparison.OrdinalIgnoreCase))
                {
                    sawTable = true;
                }
                else if (!word.Equals("TEMP", StringComparison.OrdinalIgnoreCase) && !word.Equals("TEMPORARY", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }
            }
            else if (word.Equals("AS", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
        }

        if (!found)
        {
            return null;
        }

        var entries = new List<SqliteTableEntry>();
        var depth = 1;
        var first = -1;
        var last = -1;
        var close = -1;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (token.Kind == SqlTokenKind.CloseParen && --depth == 0)
            {
                AddEntry(sql, first, last, entries);
                close = token.Start;
                break;
            }

            if (token.Kind == SqlTokenKind.Comma && depth == 1)
            {
                AddEntry(sql, first, last, entries);
                first = -1;
                continue;
            }

            if (token.Kind == SqlTokenKind.OpenParen)
            {
                depth++;
            }

            if (first < 0)
            {
                first = token.Start;
            }

            last = token.End;
        }

        if (close < 0 || !entries.Exists(e => e.IsColumn))
        {
            return null;
        }

        var suffix = sql[(close + 1)..].Trim();
        return new SqliteCreateTable(entries, suffix, IsWithoutRowid(suffix));
    }

    /// <summary>Writes the table back under <paramref name="quotedTableName"/> with the given entries and the original options.</summary>
    public static string Render(string quotedTableName, IReadOnlyList<SqliteTableEntry> entries, string suffix)
    {
        var sql = new StringBuilder("CREATE TABLE ").Append(quotedTableName).Append(" (\n  ");
        for (var i = 0; i < entries.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(",\n  ");
            }

            sql.Append(entries[i].Text);
        }

        sql.Append("\n)");
        if (suffix.Length > 0)
        {
            sql.Append(' ').Append(suffix);
        }

        return sql.ToString();
    }

    public static SqliteColumnParts? ParseColumn(string text)
    {
        var units = Units(text);
        if (units.Count == 0 || Identifier(text, units[0]) is not { } name)
        {
            return null;
        }

        var i = 1;
        while (i < units.Count && !(units[i].Word is { } word && ClauseStarts.Contains(word)))
        {
            i++;
        }

        var clauses = new List<SqliteColumnClause>();
        var clauseStart = -1;
        string? kind = null;
        string? constraintName = null;
        var suppressThrough = -1;
        for (var j = i; j < units.Count; j++)
        {
            if (j <= suppressThrough || !IsClauseBoundary(units, j))
            {
                continue;
            }

            if (clauseStart >= 0)
            {
                clauses.Add(new SqliteColumnClause(kind!, constraintName, clauseStart, units[j - 1].End));
            }

            clauseStart = units[j].Start;
            kind = units[j].Word;
            constraintName = null;
            if (kind == "CONSTRAINT")
            {
                // The name and the keyword after it belong to this clause; the keyword says what kind it is.
                suppressThrough = j + 2;
                constraintName = j + 1 < units.Count ? Identifier(text, units[j + 1]) : null;
                kind = j + 2 < units.Count ? units[j + 2].Word ?? "CONSTRAINT" : "CONSTRAINT";
            }
        }

        if (clauseStart >= 0)
        {
            clauses.Add(new SqliteColumnClause(kind!, constraintName, clauseStart, units[^1].End));
        }

        return new SqliteColumnParts(name, clauses);
    }

    /// <summary>
    /// The column definition with a new type, nullability and default, keeping every other clause as written.
    /// </summary>
    public static string? RewriteColumn(string text, string quotedName, string dataType, bool isNullable, string? defaultExpression)
    {
        if (ParseColumn(text) is not { } parts)
        {
            return null;
        }

        var sql = new StringBuilder(quotedName);
        if (!string.IsNullOrWhiteSpace(dataType))
        {
            sql.Append(' ').Append(dataType.Trim());
        }

        foreach (var clause in parts.Clauses)
        {
            if (clause.Kind is "NOT" or "NULL" or "DEFAULT")
            {
                continue;
            }

            sql.Append(' ').Append(text.AsSpan(clause.Start, clause.End - clause.Start));
        }

        if (!isNullable)
        {
            sql.Append(" NOT NULL");
        }

        if (!string.IsNullOrWhiteSpace(defaultExpression))
        {
            sql.Append(" DEFAULT ").Append(DefaultValue(defaultExpression));
        }

        return sql.ToString();
    }

    /// <summary>The definition without one of its clauses, closing the gap it leaves.</summary>
    public static string RemoveClause(string text, SqliteColumnClause clause)
    {
        var head = text[..clause.Start].TrimEnd();
        var tail = text[clause.End..].TrimStart();
        return tail.Length == 0 ? head : string.Concat(head, " ", tail);
    }

    /// <summary>
    /// SQLite takes a literal, a signed number or a parenthesized expression after DEFAULT; anything else is
    /// wrapped so a function call such as <c>datetime('now')</c> is accepted.
    /// </summary>
    public static string DefaultValue(string expression)
    {
        var trimmed = expression.Trim();
        var units = Units(trimmed);
        if (units.Count == 1 && units[0].Kind is SqlTokenKind.String or SqlTokenKind.Number or SqlTokenKind.OpenParen)
        {
            return trimmed;
        }

        if (units.Count == 1 && units[0].Word is "NULL" or "TRUE" or "FALSE" or "CURRENT_TIME" or "CURRENT_DATE" or "CURRENT_TIMESTAMP")
        {
            return trimmed;
        }

        if (units.Count == 2 && units[0].Kind == SqlTokenKind.Operator && units[1].Kind == SqlTokenKind.Number)
        {
            return trimmed;
        }

        return string.Concat("(", trimmed, ")");
    }

    /// <summary>Whether a table constraint names the column, so dropping the column has to drop it too.</summary>
    public static bool ConstraintMentions(string text, string column)
    {
        var units = Units(text);
        var kindIndex = 0;
        if (units.Count > 2 && units[0].Word == "CONSTRAINT")
        {
            kindIndex = 2;
        }

        var kind = kindIndex < units.Count ? units[kindIndex].Word : null;
        if (kind is "PRIMARY" or "UNIQUE" or "FOREIGN")
        {
            // Only the constrained column list counts; a parent column of the same name in REFERENCES does not.
            for (var i = kindIndex; i < units.Count; i++)
            {
                if (units[i].Kind == SqlTokenKind.OpenParen)
                {
                    return ContainsIdentifier(text.AsSpan(units[i].Start, units[i].End - units[i].Start), column);
                }
            }

            return false;
        }

        return ContainsIdentifier(text, column);
    }

    /// <summary>Every foreign key the statement declares, with its name when it has a CONSTRAINT clause.</summary>
    public static List<SqliteDeclaredForeignKey> DeclaredForeignKeys(SqliteCreateTable table)
    {
        var keys = new List<SqliteDeclaredForeignKey>();
        for (var e = 0; e < table.Entries.Count; e++)
        {
            var entry = table.Entries[e];
            if (entry.IsColumn)
            {
                if (ParseColumn(entry.Text) is not { } parts)
                {
                    continue;
                }

                foreach (var clause in parts.Clauses)
                {
                    if (clause.Kind == "REFERENCES")
                    {
                        keys.Add(new SqliteDeclaredForeignKey(clause.ConstraintName, [parts.Name], e, clause));
                    }
                }

                continue;
            }

            var units = Units(entry.Text);
            var index = 0;
            string? name = null;
            if (units.Count > 2 && units[0].Word == "CONSTRAINT")
            {
                name = Identifier(entry.Text, units[1]);
                index = 2;
            }

            if (index >= units.Count || units[index].Word != "FOREIGN")
            {
                continue;
            }

            for (var i = index; i < units.Count; i++)
            {
                if (units[i].Kind == SqlTokenKind.OpenParen)
                {
                    keys.Add(new SqliteDeclaredForeignKey(name, IdentifiersIn(entry.Text, units[i]), e, null));
                    break;
                }
            }
        }

        return keys;
    }

    /// <summary>The name the app shows for a key SQLite stored without one.</summary>
    public static string SynthesizedForeignKeyName(string table, IReadOnlyList<string> columns) =>
        string.Concat("fk_", table, "_", string.Join('_', columns));

    public static bool SameColumns(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        if (left.Count != right.Count)
        {
            return false;
        }

        for (var i = 0; i < left.Count; i++)
        {
            if (!string.Equals(left[i], right[i], StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Reads a trigger's timing and event out of its CREATE TRIGGER text, which is all SQLite keeps.</summary>
    public static (string Timing, string Event) TriggerTimingAndEvent(string sql)
    {
        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, Features);
        var timing = "BEFORE";
        var evt = string.Empty;
        while (lexer.TryRead(out var token))
        {
            if (token.Kind != SqlTokenKind.Word)
            {
                continue;
            }

            var word = token.Slice(span);
            if (word.Equals("ON", StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            if (word.Equals("AFTER", StringComparison.OrdinalIgnoreCase))
            {
                timing = "AFTER";
            }
            else if (word.Equals("INSTEAD", StringComparison.OrdinalIgnoreCase))
            {
                timing = "INSTEAD OF";
            }
            else if (word.Equals("INSERT", StringComparison.OrdinalIgnoreCase) || word.Equals("UPDATE", StringComparison.OrdinalIgnoreCase)
                || word.Equals("DELETE", StringComparison.OrdinalIgnoreCase))
            {
                evt = word.ToString().ToUpperInvariant();
            }
        }

        return (timing, evt);
    }

    private static void AddEntry(string sql, int first, int last, List<SqliteTableEntry> entries)
    {
        if (first < 0 || last <= first)
        {
            return;
        }

        var text = sql[first..last];
        entries.Add(new SqliteTableEntry(text, LeadingColumnName(text)));
    }

    private static string? LeadingColumnName(string text)
    {
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, Features);
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            return token.Kind switch
            {
                SqlTokenKind.QuotedIdentifier or SqlTokenKind.String => Unquote(token.Slice(span)),
                SqlTokenKind.Word when !TableConstraintKeywords.Contains(token.Slice(span).ToString()) => token.Slice(span).ToString(),
                _ => null,
            };
        }

        return null;
    }

    private static bool IsWithoutRowid(string suffix)
    {
        var span = suffix.AsSpan();
        var lexer = new SqlLexer(span, Features);
        var previousWasWithout = false;
        while (lexer.TryRead(out var token))
        {
            if (token.Kind != SqlTokenKind.Word)
            {
                continue;
            }

            var word = token.Slice(span);
            if (previousWasWithout && word.Equals("ROWID", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            previousWasWithout = word.Equals("WITHOUT", StringComparison.OrdinalIgnoreCase);
        }

        return false;
    }

    private static bool IsClauseBoundary(List<Unit> units, int j)
    {
        if (units[j].Word is not { } word || !ClauseStarts.Contains(word))
        {
            return false;
        }

        var previous = j > 0 ? units[j - 1].Word : null;
        var next = j + 1 < units.Count ? units[j + 1].Word : null;
        return word switch
        {
            // ON DELETE SET NULL and SET DEFAULT sit inside a REFERENCES clause.
            "NULL" => previous is not ("SET" or "NOT"),
            "DEFAULT" => previous != "SET",
            "NOT" => next != "DEFERRABLE",
            "AS" => previous != "ALWAYS",
            _ => true,
        };
    }

    private static bool ContainsIdentifier(ReadOnlySpan<char> text, string column)
    {
        var lexer = new SqlLexer(text, Features);
        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Word && token.Slice(text).Equals(column, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            if (token.Kind == SqlTokenKind.QuotedIdentifier && string.Equals(Unquote(token.Slice(text)), column, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static List<string> IdentifiersIn(string text, Unit group)
    {
        var span = text.AsSpan(group.Start, group.End - group.Start);
        var lexer = new SqlLexer(span, Features);
        var names = new List<string>();
        while (lexer.TryRead(out var token))
        {
            if (token.Kind is SqlTokenKind.QuotedIdentifier or SqlTokenKind.String)
            {
                names.Add(Unquote(token.Slice(span)));
            }
            else if (token.Kind == SqlTokenKind.Word && !token.Slice(span).Equals("COLLATE", StringComparison.OrdinalIgnoreCase)
                && !token.Slice(span).Equals("ASC", StringComparison.OrdinalIgnoreCase) && !token.Slice(span).Equals("DESC", StringComparison.OrdinalIgnoreCase))
            {
                names.Add(token.Slice(span).ToString());
            }
        }

        return names;
    }

    private static string? Identifier(string text, Unit unit) => unit.Kind switch
    {
        SqlTokenKind.Word => text[unit.Start..unit.End],
        SqlTokenKind.QuotedIdentifier or SqlTokenKind.String => Unquote(text.AsSpan(unit.Start, unit.End - unit.Start)),
        _ => null,
    };

    internal static string Unquote(ReadOnlySpan<char> quoted)
    {
        if (quoted.Length < 2)
        {
            return quoted.ToString();
        }

        var open = quoted[0];
        var inner = quoted[1..^1].ToString();
        return open switch
        {
            '"' => inner.Replace("\"\"", "\"", StringComparison.Ordinal),
            '`' => inner.Replace("``", "`", StringComparison.Ordinal),
            '\'' => inner.Replace("''", "'", StringComparison.Ordinal),
            _ => inner,
        };
    }

    /// <summary>Tokens with every parenthesized group folded into one unit, so a clause scan sees only the top level.</summary>
    private static List<Unit> Units(string text)
    {
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, Features);
        var units = new List<Unit>();
        var depth = 0;
        var groupStart = 0;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (depth > 0)
            {
                if (token.Kind == SqlTokenKind.OpenParen)
                {
                    depth++;
                }
                else if (token.Kind == SqlTokenKind.CloseParen && --depth == 0)
                {
                    units.Add(new Unit(SqlTokenKind.OpenParen, groupStart, token.End, null));
                }

                continue;
            }

            if (token.Kind == SqlTokenKind.OpenParen)
            {
                depth = 1;
                groupStart = token.Start;
                continue;
            }

            var word = token.Kind == SqlTokenKind.Word ? token.Slice(span).ToString().ToUpperInvariant() : null;
            units.Add(new Unit(token.Kind, token.Start, token.End, word));
        }

        if (depth > 0)
        {
            units.Add(new Unit(SqlTokenKind.OpenParen, groupStart, text.Length, null));
        }

        return units;
    }

    private readonly record struct Unit(SqlTokenKind Kind, int Start, int End, string? Word);
}
