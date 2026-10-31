using System.Collections.Frozen;
using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Sql;

namespace TablePro.Mcp.Tools;

/// <summary>What the gate found in a client's query: the one statement to run and whether it only reads.</summary>
internal sealed record GatedStatement(string Sql, StatementKind Kind, bool IsRead, bool IsDestructive);

/// <summary>
/// Decides whether a client's statement reads or writes. It is stricter than Safe Mode's classifier because nobody
/// reads the statement before a read runs: one statement per call, so what the user approves is all that runs, and a
/// statement only reads when the classifier says so and no data-changing verb appears anywhere in it.
/// </summary>
internal static class McpStatementGate
{
    // Verbs that change data, the catalog or the server, wherever they appear outside strings and comments: inside a
    // CTE, after EXPLAIN ANALYZE, or as the second statement of a SQL Server batch that needs no semicolon. A false
    // positive costs a refusal on a read-only connection or an approval prompt; a miss could run a write unasked.
    // Words that are common column names (comment, load, lock) are left to the classifier, which sees them leading.
    private static readonly FrozenSet<string> WriteVerbs = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "REPLACE", "TRUNCATE", "DROP", "CREATE", "ALTER", "RENAME",
        "GRANT", "REVOKE", "DENY", "EXEC", "EXECUTE", "CALL", "DO", "COPY", "IMPORT", "ATTACH", "DETACH",
        "VACUUM", "REINDEX", "CLUSTER", "BACKUP", "RESTORE", "DBCC", "KILL", "SHUTDOWN", "INTO", "INSTALL", "RECONFIGURE");

    private static readonly FrozenSet<string>.AlternateLookup<ReadOnlySpan<char>> WriteVerbLookup =
        WriteVerbs.GetAlternateLookup<ReadOnlySpan<char>>();

    public static GatedStatement Analyze(string query, SqlDialect dialect, int maxQueryBytes)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(dialect);
        if (string.IsNullOrWhiteSpace(query))
        {
            throw McpToolException.Invalid("the query is empty");
        }

        var bytes = Encoding.UTF8.GetByteCount(query);
        if (bytes > maxQueryBytes)
        {
            throw McpToolException.Invalid($"the query is {bytes} bytes; the limit is {maxQueryBytes}");
        }

        // MySQL runs the body of a /*! ... */ comment, which every lexer here skips as a comment.
        if (dialect.SupportsDelimiterDirective && (query.Contains("/*!", StringComparison.Ordinal) || query.Contains("/*M!", StringComparison.Ordinal)))
        {
            throw McpToolException.Invalid("MySQL executable comments (/*! ... */) are not accepted; write the statement without them");
        }

        var primary = Scan(query, dialect.LexerFeatures);
        if (primary.Unterminated)
        {
            throw McpToolException.Invalid("the query leaves a string, quoted name or comment open");
        }

        // The server may read backslashes in strings differently from the client (NO_BACKSLASH_ESCAPES,
        // standard_conforming_strings), and then end the statement somewhere else. Both readings must agree it is one.
        var alternate = Scan(query, dialect.LexerFeatures ^ SqlLexerFeatures.BackslashEscapes);

        string sql;
        if (dialect.BatchSeparator is not null)
        {
            var batches = SqlScript.Split(query, dialect).Where(s => !string.IsNullOrWhiteSpace(s.Text)).ToArray();
            if (batches.Length != 1)
            {
                throw McpToolException.Invalid("send one batch per call; GO separates batches");
            }

            sql = batches[0].Text.Trim();
        }
        else
        {
            if (primary.Statements > 1)
            {
                throw McpToolException.Invalid("send one statement per call");
            }

            if (alternate.Statements > 1)
            {
                throw McpToolException.Invalid("the query can read as more than one statement under the server's settings; send one statement per call");
            }

            sql = query[primary.Start..primary.End];
        }

        if (sql.Length == 0)
        {
            throw McpToolException.Invalid("the query is empty");
        }

        var kind = StatementClassifier.Classify(sql, dialect);
        var hasWriteVerb = primary.HasWriteVerb || alternate.HasWriteVerb;
        if (kind == StatementKind.Read && hasWriteVerb)
        {
            kind = StatementKind.Write;
        }

        return new GatedStatement(sql, kind, kind == StatementKind.Read, IsDestructive(sql, dialect));
    }

    /// <summary>Whether an External Clients level and Safe Mode let a statement of this kind run at all.</summary>
    public static McpToolException? Refusal(ConnectionProfile profile, GatedStatement statement)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (statement.IsRead)
        {
            return null;
        }

        if (profile.ExternalAccess != ExternalAccessLevel.ReadWrite)
        {
            return new McpToolException(McpToolErrorCode.Denied,
                $"\"{profile.Name}\" lets MCP clients read only; the user can allow writes under External Clients in the connection's settings");
        }

        if (profile.IsReadOnly)
        {
            return new McpToolException(McpToolErrorCode.Denied, $"Safe Mode on \"{profile.Name}\" is Read-Only, which refuses every write");
        }

        return null;
    }

    private static ScanResult Scan(string query, SqlLexerFeatures features)
    {
        var text = query.AsSpan();
        var lexer = new SqlLexer(text, features);
        var result = new ScanResult { Start = -1 };
        var statementHasTokens = false;
        SqlToken previous = default;
        var hasPrevious = false;
        SqlToken pendingWord = default;
        var hasPendingWord = false;

        while (lexer.TryRead(out var token))
        {
            if (token.IsUnterminated)
            {
                result.Unterminated = true;
                break;
            }

            if (token.IsTrivia)
            {
                continue;
            }

            // A verb directly followed by "(" is a function such as REPLACE(...) or INSERT(...) in MySQL.
            if (hasPendingWord)
            {
                if (token.Kind != SqlTokenKind.OpenParen)
                {
                    result.HasWriteVerb = true;
                }

                hasPendingWord = false;
            }

            if (token.Kind == SqlTokenKind.Semicolon)
            {
                statementHasTokens = false;
                previous = token;
                hasPrevious = true;
                continue;
            }

            if (!statementHasTokens)
            {
                statementHasTokens = true;
                result.Statements++;
                if (result.Start < 0)
                {
                    result.Start = token.Start;
                }
            }

            result.End = token.End;

            // A name after a dot is a column or table, such as t.update, never a verb.
            var afterDot = hasPrevious && previous.Kind == SqlTokenKind.Dot;
            if (token.Kind == SqlTokenKind.Word && !afterDot && WriteVerbLookup.Contains(token.Slice(text)))
            {
                pendingWord = token;
                hasPendingWord = true;
            }

            previous = token;
            hasPrevious = true;
        }

        if (hasPendingWord && pendingWord.Length > 0)
        {
            result.HasWriteVerb = true;
        }

        if (result.Start < 0)
        {
            result.Start = result.End = 0;
        }

        return result;
    }

    private static bool IsDestructive(string sql, SqlDialect dialect)
    {
        var text = sql.AsSpan();
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        ReadOnlySpan<char> first = default;
        var hasWhere = false;
        var hasDrop = false;
        while (lexer.TryRead(out var token))
        {
            if (token.Kind != SqlTokenKind.Word)
            {
                continue;
            }

            var word = token.Slice(text);
            if (first.IsEmpty)
            {
                first = word;
                continue;
            }

            hasWhere |= word.Equals("WHERE", StringComparison.OrdinalIgnoreCase);
            hasDrop |= word.Equals("DROP", StringComparison.OrdinalIgnoreCase);
        }

        return first.Equals("DROP", StringComparison.OrdinalIgnoreCase)
            || first.Equals("TRUNCATE", StringComparison.OrdinalIgnoreCase)
            || (first.Equals("ALTER", StringComparison.OrdinalIgnoreCase) && hasDrop)
            || ((first.Equals("DELETE", StringComparison.OrdinalIgnoreCase) || first.Equals("UPDATE", StringComparison.OrdinalIgnoreCase)) && !hasWhere);
    }

    private struct ScanResult
    {
        public int Statements;
        public int Start;
        public int End;
        public bool Unterminated;
        public bool HasWriteVerb;
    }
}

/// <summary>
/// Statements that hold a client's read to read-only at the server, so a function with side effects the gate cannot
/// see still fails. Engines without such a mode run reads as they are.
/// </summary>
internal sealed record ReadGuard(string Begin, string End)
{
    public static ReadGuard? For(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => new("BEGIN READ ONLY", "ROLLBACK"),
        DatabaseEngine.MySql or DatabaseEngine.MariaDb => new("START TRANSACTION READ ONLY", "ROLLBACK"),

        // query_only is a connection setting that outlives the call in the pool, so End always runs.
        DatabaseEngine.Sqlite => new("PRAGMA query_only = ON", "PRAGMA query_only = OFF"),
        _ => null,
    };
}
