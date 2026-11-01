using System.Data;
using System.Data.Common;
using System.Diagnostics;
using Oracle.ManagedDataAccess.Client;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// The editor's transaction. ODP.NET commits every command run outside a transaction it was asked to begin, so a
/// DELETE followed by ROLLBACK lost the rows. An editor tab's channel begins one before the first statement that can
/// change data, as SQL*Plus and SQL Developer leave Oracle's own implicit transaction open, and ends it on COMMIT or
/// ROLLBACK. Other callers of the channel (an import, a copy, MCP) keep ODP.NET's commit per statement.
/// </summary>
public sealed partial class OracleSession
{
    protected override AdoNetQueryChannel CreateChannel(DbConnection connection) => new OracleQueryChannel(this, connection);

    private sealed class OracleQueryChannel(OracleSession session, DbConnection connection) : AdoNetQueryChannel(session, connection)
    {
        protected override async Task<StatementResult> RunStatementAsync(string sql, ExecuteOptions options, CancellationToken cancellationToken)
        {
            var role = OracleEditorStatements.Role(sql);
            if (Transaction is { } held)
            {
                if (!Connection.State.HasFlag(ConnectionState.Open) || Connection.State.HasFlag(ConnectionState.Broken))
                {
                    // The session that held the changes is gone and the server rolled them back; running the rest of
                    // the transaction's statements on a new session would commit half of it.
                    Transaction = null;
                    await DisposeQuietlyAsync(held);
                    return Failed(sql, [], Stopwatch.StartNew(), CoreStrings.Get("Driver/TransactionLost"));
                }

                if (role is OracleStatementRole.Commit or OracleStatementRole.Rollback)
                {
                    return await EndAsync(sql, held, role == OracleStatementRole.Commit, cancellationToken);
                }
            }

            var opened = false;
            if (Transaction is null && options.EditorTransaction && role is OracleStatementRole.Write or OracleStatementRole.Procedural)
            {
                try
                {
                    await EnsureOpenAsync(cancellationToken);
                    Transaction = await Connection.BeginTransactionAsync(cancellationToken);
                    opened = true;
                }
                catch (Exception ex) when (ex is OracleException or InvalidOperationException)
                {
                    return Failed(sql, [], Stopwatch.StartNew(), ex.Message);
                }
            }

            var result = await base.RunStatementAsync(sql, options, cancellationToken);
            if (Transaction is { } open)
            {
                // DDL commits whatever was pending before it runs, and a PL/SQL block or a failed first write may
                // leave nothing open on the server; the tab then has no transaction to end.
                if (role == OracleStatementRole.Ddl || ((role == OracleStatementRole.Procedural || !result.Succeeded) && !await HoldsServerTransactionAsync()))
                {
                    Transaction = null;
                    await DisposeQuietlyAsync(open);
                }
                else if (opened)
                {
                    result = result with { Messages = [.. result.Messages ?? [], CoreStrings.Get("Driver/TransactionStartedByWrite")] };
                }
            }

            return result;
        }

        private async Task<StatementResult> EndAsync(string sql, DbTransaction transaction, bool commit, CancellationToken cancellationToken)
        {
            var stopwatch = Stopwatch.StartNew();

            // Oracle ends the transaction even when COMMIT fails, as it does on a deferred constraint, so the tab no
            // longer holds one either way.
            Transaction = null;
            try
            {
                if (commit)
                {
                    await transaction.CommitAsync(cancellationToken);
                }
                else
                {
                    await transaction.RollbackAsync(cancellationToken);
                }
            }
            catch (Exception ex) when (ex is OracleException or InvalidOperationException or OperationCanceledException)
            {
                return Failed(sql, [], stopwatch, ex.Message);
            }
            finally
            {
                await DisposeQuietlyAsync(transaction);
            }

            return new StatementResult(sql, [], -1, stopwatch.Elapsed, Messages: [.. TakeMessages(), CoreStrings.Get(commit ? "Driver/Committed" : "Driver/RolledBack")]);
        }

        /// <summary>Asks the server, since a block may have committed or rolled back inside itself.</summary>
        private async Task<bool> HoldsServerTransactionAsync()
        {
            try
            {
                await using var command = Connection.CreateCommand();
                command.CommandText = OracleCatalog.LocalTransactionId;
                command.Transaction = Transaction;
                return await command.ExecuteScalarAsync(CancellationToken.None) is not (null or DBNull);
            }
            catch (Exception ex) when (ex is OracleException or InvalidOperationException)
            {
                // Unable to tell, so the transaction is kept: a ROLLBACK the user runs then still has one to end.
                return true;
            }
        }

        private static async Task DisposeQuietlyAsync(DbTransaction transaction)
        {
            try
            {
                await transaction.DisposeAsync();
            }
            catch (Exception ex) when (ex is OracleException or InvalidOperationException)
            {
            }
        }
    }
}

internal enum OracleStatementRole
{
    /// <summary>Reads, and needs no transaction: SELECT, EXPLAIN PLAN, DESCRIBE.</summary>
    Query,

    /// <summary>Changes data or holds locks, so it opens the tab's transaction.</summary>
    Write,

    /// <summary>A PL/SQL block or call: it may write, commit or roll back inside itself.</summary>
    Procedural,

    /// <summary>A schema change, which Oracle commits together with whatever was pending.</summary>
    Ddl,

    /// <summary>Changes the session, not the data, or acts on a transaction only when one is open.</summary>
    Session,

    Commit,

    Rollback,
}

/// <summary>What an editor statement does to the tab's transaction, read from its leading words.</summary>
internal static class OracleEditorStatements
{
    public static OracleStatementRole Role(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, OracleDialect.Instance.LexerFeatures);
        ReadOnlySpan<char> first = default;
        ReadOnlySpan<char> previous = default;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (token.Kind != SqlTokenKind.Word)
            {
                if (first.IsEmpty)
                {
                    return OracleStatementRole.Procedural;
                }

                previous = default;
                continue;
            }

            var word = token.Slice(span);
            if (first.IsEmpty)
            {
                first = word;
                if (Leading(word) is { } decided)
                {
                    return decided;
                }

                previous = word;
                continue;
            }

            if (Is(first, "SELECT") || Is(first, "WITH"))
            {
                // SELECT ... FOR UPDATE locks its rows until the transaction ends.
                if (Is(previous, "FOR") && Is(word, "UPDATE"))
                {
                    return OracleStatementRole.Write;
                }

                previous = word;
                continue;
            }

            return Second(first, word);
        }

        return first.IsEmpty || Is(first, "SELECT") || Is(first, "WITH") ? OracleStatementRole.Query : Second(first, default);
    }

    /// <summary>The role the first word decides alone, or null when the next word decides it.</summary>
    private static OracleStatementRole? Leading(ReadOnlySpan<char> word)
    {
        if (Is(word, "SELECT") || Is(word, "WITH") || Is(word, "COMMIT") || Is(word, "ROLLBACK") || Is(word, "ALTER") || Is(word, "SET"))
        {
            return null;
        }

        if (Is(word, "EXPLAIN") || Is(word, "DESC") || Is(word, "DESCRIBE") || Is(word, "SHOW"))
        {
            return OracleStatementRole.Query;
        }

        if (Is(word, "INSERT") || Is(word, "UPDATE") || Is(word, "DELETE") || Is(word, "MERGE") || Is(word, "LOCK") || Is(word, "SAVEPOINT"))
        {
            return OracleStatementRole.Write;
        }

        if (Is(word, "CREATE") || Is(word, "DROP") || Is(word, "TRUNCATE") || Is(word, "RENAME") || Is(word, "GRANT") || Is(word, "REVOKE")
            || Is(word, "COMMENT") || Is(word, "AUDIT") || Is(word, "NOAUDIT") || Is(word, "ANALYZE") || Is(word, "PURGE") || Is(word, "FLASHBACK")
            || Is(word, "ASSOCIATE") || Is(word, "DISASSOCIATE"))
        {
            return OracleStatementRole.Ddl;
        }

        return OracleStatementRole.Procedural;
    }

    private static OracleStatementRole Second(ReadOnlySpan<char> first, ReadOnlySpan<char> second)
    {
        if (Is(first, "COMMIT"))
        {
            // COMMIT FORCE settles an in-doubt distributed transaction, not this tab's.
            return Is(second, "FORCE") ? OracleStatementRole.Session : OracleStatementRole.Commit;
        }

        if (Is(first, "ROLLBACK"))
        {
            // ROLLBACK TO SAVEPOINT stays inside the transaction; ROLLBACK FORCE is another transaction's.
            return Is(second, "TO") || Is(second, "FORCE") ? OracleStatementRole.Session : OracleStatementRole.Rollback;
        }

        if (Is(first, "ALTER"))
        {
            return Is(second, "SESSION") || Is(second, "SYSTEM") ? OracleStatementRole.Session : OracleStatementRole.Ddl;
        }

        // SET TRANSACTION and SET CONSTRAINTS shape the transaction they open; SET ROLE changes the session.
        return Is(second, "TRANSACTION") || Is(second, "CONSTRAINT") || Is(second, "CONSTRAINTS") ? OracleStatementRole.Write : OracleStatementRole.Session;
    }

    private static bool Is(ReadOnlySpan<char> word, string keyword) => word.Equals(keyword, StringComparison.OrdinalIgnoreCase);
}
