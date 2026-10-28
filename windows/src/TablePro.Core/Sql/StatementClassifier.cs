namespace TablePro.Core.Sql;

public enum StatementKind
{
    Read,
    Write,
    Ddl,
    Transaction,
    Session,
    Unknown,
}

public static class StatementKindExtensions
{
    /// <summary>What Safe Mode treats as changing the database. A call it cannot see into counts as one.</summary>
    public static bool IsWrite(this StatementKind kind) => kind is StatementKind.Write or StatementKind.Ddl or StatementKind.Unknown;
}

/// <summary>Reads a statement's leading keywords to decide what it does, as the macOS app's history and Safe Mode do.</summary>
public static class StatementClassifier
{
    /// <summary>
    /// The kind of the first statement, unless a later one writes: a SQL Server batch or a pasted script runs every
    /// statement it holds, so a write behind a read must not pass as a read.
    /// </summary>
    public static StatementKind Classify(string sql, SqlDialect dialect)
    {
        ArgumentNullException.ThrowIfNull(sql);
        ArgumentNullException.ThrowIfNull(dialect);
        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, dialect.LexerFeatures);
        StatementKind? result = null;
        bool atEnd;
        do
        {
            var kind = ClassifyNext(span, ref lexer, out atEnd);
            if (kind is { } k && (result is null || (!result.Value.IsWrite() && k.IsWrite())))
            {
                result = k;
            }
        }
        while (!atEnd);

        return result ?? StatementKind.Unknown;
    }

    /// <summary>Classifies the statement up to the next <c>;</c>, or returns null when it is empty.</summary>
    private static StatementKind? ClassifyNext(ReadOnlySpan<char> span, ref SqlLexer lexer, out bool atEnd)
    {
        ReadOnlySpan<char> first = default;
        StatementKind? decided = null;
        var depth = 0;
        var sawInto = false;

        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Semicolon)
            {
                atEnd = false;
                return Finish(first, decided, sawInto);
            }

            if (token.IsTrivia || decided is not null)
            {
                continue;
            }

            if (token.Kind == SqlTokenKind.OpenParen)
            {
                depth++;
                continue;
            }

            if (token.Kind == SqlTokenKind.CloseParen)
            {
                depth--;
                continue;
            }

            if (token.Kind != SqlTokenKind.Word)
            {
                if (first.IsEmpty)
                {
                    decided = StatementKind.Unknown;
                }

                continue;
            }

            var word = token.Slice(span);
            if (first.IsEmpty)
            {
                first = word;
                decided = ClassifyLeading(word);
                continue;
            }

            decided = ClassifyInner(word);
            if (depth == 0 && word.Equals("INTO", StringComparison.OrdinalIgnoreCase))
            {
                sawInto = true;
            }
        }

        atEnd = true;
        return Finish(first, decided, sawInto);
    }

    private static StatementKind? Finish(ReadOnlySpan<char> first, StatementKind? decided, bool sawInto)
    {
        if (decided is not null)
        {
            return decided;
        }

        if (first.IsEmpty)
        {
            return null;
        }

        return sawInto ? StatementKind.Write : StatementKind.Read;
    }

    /// <summary>
    /// A word inside a statement that only reads so far. A data-changing verb at any depth writes, and so does a
    /// schema change or a call that follows the read in a batch that needs no <c>;</c>.
    /// </summary>
    private static StatementKind? ClassifyInner(ReadOnlySpan<char> word)
    {
        if (IsAny(word, "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "TRUNCATE"))
        {
            return StatementKind.Write;
        }

        if (IsAny(word, "CREATE", "ALTER", "DROP"))
        {
            return StatementKind.Ddl;
        }

        if (IsAny(word, "EXEC", "EXECUTE"))
        {
            return StatementKind.Unknown;
        }

        return null;
    }

    private static StatementKind? ClassifyLeading(ReadOnlySpan<char> word)
    {
        // EXPLAIN ANALYZE runs the statement it explains on PostgreSQL, so EXPLAIN reads only what its statement reads.
        if (IsAny(word, "SELECT", "WITH", "VALUES", "TABLE", "EXPLAIN"))
        {
            return null;
        }

        if (IsAny(word, "SHOW", "DESCRIBE", "DESC", "PRAGMA", "HELP", "SUMMARIZE", "FROM"))
        {
            return StatementKind.Read;
        }

        if (IsAny(word, "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT", "TRUNCATE", "COPY", "LOAD", "IMPORT", "VACUUM", "REINDEX", "CLUSTER", "ANALYZE", "OPTIMIZE"))
        {
            return StatementKind.Write;
        }

        if (IsAny(word, "CREATE", "ALTER", "DROP", "RENAME", "COMMENT", "GRANT", "REVOKE", "ATTACH", "DETACH"))
        {
            return StatementKind.Ddl;
        }

        if (IsAny(word, "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "END"))
        {
            return StatementKind.Transaction;
        }

        if (IsAny(word, "USE", "SET", "RESET", "DECLARE", "PRINT", "LISTEN", "UNLISTEN", "DISCARD"))
        {
            return StatementKind.Session;
        }

        return StatementKind.Unknown;
    }

    private static bool IsAny(ReadOnlySpan<char> word, params ReadOnlySpan<string> candidates)
    {
        foreach (var candidate in candidates)
        {
            if (word.Equals(candidate, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
