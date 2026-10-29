using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Core.Import;

/// <summary>What a SQL import does when a statement fails, the three modes of the macOS SQL import plugin.</summary>
public enum SqlImportErrorHandling
{
    /// <summary>Stops and rolls back everything the import changed, when it runs in a transaction.</summary>
    StopAndRollback,

    /// <summary>Stops and keeps what ran before the failure.</summary>
    StopAndCommit,

    /// <summary>Records the failure and runs the rest. Never in a transaction, since one failure would abort it on PostgreSQL.</summary>
    SkipAndContinue,
}

/// <param name="ErrorHandling">What a failing statement does.</param>
/// <param name="WrapInTransaction">Runs every statement in one transaction. Ignored when skipping errors.</param>
/// <param name="DisableForeignKeyChecks">Turns foreign key checks off for the import, where the engine can.</param>
/// <param name="BatchSize">Statements sent to the channel at a time; each still reports its own result.</param>
/// <param name="Encoding">How the file's bytes are read; null reads UTF-8. A byte order mark wins either way.</param>
public sealed record SqlImportOptions(
    SqlImportErrorHandling ErrorHandling = SqlImportErrorHandling.StopAndRollback,
    bool WrapInTransaction = true,
    bool DisableForeignKeyChecks = true,
    int BatchSize = 100,
    SqlImportEncoding? Encoding = null);

public readonly record struct SqlImportProgress(long Executed, long Skipped, long BytesRead, long TotalBytes);

/// <summary>A statement that failed, cut to 200 characters, with the line it starts on.</summary>
public sealed record SqlImportError(string Statement, int Line, string Message);

public sealed record SqlImportResult(long Executed, long Skipped, IReadOnlyList<SqlImportError> Errors, TimeSpan Elapsed);

/// <summary>A statement stopped the import. The message names the line and the database's reason, and a failed rollback after it.</summary>
public sealed class SqlImportException : Exception
{
    public SqlImportException()
    {
    }

    public SqlImportException(string message)
        : base(message)
    {
    }

    public SqlImportException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public SqlImportException(SqlImportError failure, long executed, string? rollbackError)
        : base(Describe(failure, rollbackError))
    {
        Failure = failure;
        Executed = executed;
        RollbackError = rollbackError;
    }

    public SqlImportError? Failure { get; }

    /// <summary>Statements that succeeded before the failure, which a rollback undid when the import ran in a transaction.</summary>
    public long Executed { get; }

    public string? RollbackError { get; }

    // The database's message rarely ends in punctuation, so the rollback's own failure goes on a line of its own.
    private static string Describe(SqlImportError failure, string? rollbackError) =>
        rollbackError is null
            ? CoreStrings.Format("Import/ScriptErrorLine", failure.Line, failure.Message)
            : CoreStrings.Format("Import/ScriptErrorLine", failure.Line, failure.Message) + "\n" + CoreStrings.Format("Import/RollbackAlsoFailed", rollbackError);
}

/// <summary>
/// Runs a SQL file on a query channel, as the macOS SQL import plugin does: split with the dialect's own rules, sent
/// in batches, with progress, an error mode, an optional transaction and foreign key checks off.
/// </summary>
/// <remarks>
/// The file is read a chunk at a time and split as it goes, so a dump of several gigabytes never sits in memory whole.
/// The last statement of a chunk may be cut, so it is carried into the next chunk and split again; every statement
/// before it is complete, because a string or comment left open runs to the end of the chunk and so belongs to the last.
/// </remarks>
public static partial class SqlFileImporter
{
    private const int MaxRecordedErrors = 1_000;
    private const int ChunkChars = 4 << 20;

    /// <summary>Opens the file, gzip included, and imports it.</summary>
    public static async Task<SqlImportResult> ImportFileAsync(
        IQueryChannel channel, string path, SqlDialect dialect, DatabaseEngine engine, SqlImportOptions options,
        IProgress<SqlImportProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(options);
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);
        Stream source = path.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? new System.IO.Compression.GZipStream(file, System.IO.Compression.CompressionMode.Decompress) : file;
        await using (source)
        {
            using var reader = options.Encoding is { } encoding
                ? new StreamReader(source, encoding.GetEncoding(), detectEncodingFromByteOrderMarks: true)
                : new StreamReader(source, detectEncodingFromByteOrderMarks: true);
            var total = file.Length;
            return await ImportAsync(channel, reader, dialect, engine, options, () => file.Position, total, progress, cancellationToken);
        }
    }

    public static async Task<SqlImportResult> ImportAsync(
        IQueryChannel channel, TextReader reader, SqlDialect dialect, DatabaseEngine engine, SqlImportOptions options,
        Func<long>? bytesRead, long totalBytes, IProgress<SqlImportProgress>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(channel);
        ArgumentNullException.ThrowIfNull(reader);
        ArgumentNullException.ThrowIfNull(dialect);
        ArgumentNullException.ThrowIfNull(options);

        var stopwatch = Stopwatch.StartNew();
        var control = SqlImportStatements.For(engine);
        var useTransaction = options.WrapInTransaction && options.ErrorHandling != SqlImportErrorHandling.SkipAndContinue && control.Commit is not null;
        var disableKeys = options.DisableForeignKeyChecks && control.ForeignKeysOff is not null;
        var execute = new ExecuteOptions(RowLimit: 100, StopOnError: options.ErrorHandling != SqlImportErrorHandling.SkipAndContinue);
        var errors = new List<SqlImportError>();
        long executed = 0, skipped = 0;
        var inTransaction = false;

        void Report() => progress?.Report(new SqlImportProgress(executed, skipped, bytesRead?.Invoke() ?? 0, totalBytes));

        try
        {
            // SQLite ignores the foreign key pragma inside a transaction, so it runs before BEGIN.
            if (disableKeys)
            {
                await RunControlAsync(channel, control.ForeignKeysOff!, cancellationToken);
            }

            if (useTransaction)
            {
                if (control.Begin is not null)
                {
                    await RunControlAsync(channel, control.Begin, cancellationToken);
                }

                inTransaction = true;
            }

            var batch = new List<(string Sql, int Line)>(Math.Max(1, options.BatchSize));
            await foreach (var statement in ReadStatementsAsync(reader, dialect, cancellationToken))
            {
                // A dump's own BEGIN and COMMIT would nest in or end the import's transaction, so the import's one stands for them.
                if (useTransaction && IsTransactionControl(statement.Sql))
                {
                    continue;
                }

                batch.Add(statement);
                if (batch.Count >= options.BatchSize)
                {
                    await RunBatchAsync(batch);
                    batch.Clear();
                }
            }

            if (batch.Count > 0)
            {
                await RunBatchAsync(batch);
            }

            if (inTransaction)
            {
                await RunControlAsync(channel, control.Commit!, cancellationToken);
                inTransaction = false;
            }

            await RestoreKeysAsync();
            Report();
            return new SqlImportResult(executed, skipped, errors, stopwatch.Elapsed);
        }
        catch (StatementFailedException failure)
        {
            string? rollbackError = null;
            if (inTransaction)
            {
                // On PostgreSQL a failure has already aborted the transaction, so its COMMIT ends it as a rollback would.
                rollbackError = await TryRunControlAsync(channel, options.ErrorHandling == SqlImportErrorHandling.StopAndCommit ? control.Commit! : control.Rollback!);
            }

            await RestoreKeysAsync();
            throw new SqlImportException(failure.Error, executed, rollbackError);
        }
        catch (Exception) when (inTransaction || disableKeys)
        {
            // A cancellation or a lost connection rolls back what ran, as macOS does, and is rethrown as it was.
            if (inTransaction)
            {
                await TryRunControlAsync(channel, control.Rollback!);
            }

            await RestoreKeysAsync();
            throw;
        }

        async Task RunBatchAsync(List<(string Sql, int Line)> statements)
        {
            var texts = new string[statements.Count];
            for (var i = 0; i < texts.Length; i++)
            {
                texts[i] = statements[i].Sql;
            }

            var index = 0;
            await foreach (var result in channel.ExecuteAsync(texts, execute, cancellationToken))
            {
                var (sql, line) = statements[index++];
                if (result.Succeeded)
                {
                    executed++;
                }
                else
                {
                    var error = new SqlImportError(Snippet(sql), line, result.Error!);
                    if (options.ErrorHandling != SqlImportErrorHandling.SkipAndContinue)
                    {
                        throw new StatementFailedException(error);
                    }

                    skipped++;
                    if (errors.Count < MaxRecordedErrors)
                    {
                        errors.Add(error);
                    }
                }
            }

            cancellationToken.ThrowIfCancellationRequested();
            Report();
        }

        async Task RestoreKeysAsync()
        {
            if (disableKeys)
            {
                await TryRunControlAsync(channel, control.ForeignKeysOn!);
            }
        }
    }

    /// <summary>The statements of a script with the line each starts on, read a chunk at a time.</summary>
    public static IAsyncEnumerable<(string Sql, int Line)> ReadStatementsAsync(TextReader reader, SqlDialect dialect, CancellationToken cancellationToken) =>
        ReadStatementsAsync(reader, dialect, ChunkChars, cancellationToken);

    /// <summary>Takes the chunk size so a test can cross chunk boundaries without a file of megabytes.</summary>
    internal static async IAsyncEnumerable<(string Sql, int Line)> ReadStatementsAsync(
        TextReader reader, SqlDialect dialect, int chunkChars, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(reader);
        ArgumentNullException.ThrowIfNull(dialect);
        var buffer = new char[chunkChars];
        var pending = new StringBuilder();
        var line = 1;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = await reader.ReadBlockAsync(buffer.AsMemory(), cancellationToken);
            var atEnd = read == 0;
            pending.Append(buffer, 0, read);
            if (pending.Length == 0)
            {
                yield break;
            }

            var text = pending.ToString();
            var statements = SqlScript.Split(text, dialect);
            var complete = atEnd ? statements.Length : Math.Max(0, statements.Length - 1);
            var carryFrom = atEnd ? text.Length : statements.Length > 0 ? statements[^1].Start : 0;
            var position = 0;
            for (var i = 0; i < complete; i++)
            {
                var statement = statements[i];
                line += CountLines(text.AsSpan(position, statement.Start - position));
                position = statement.Start;
                if (!string.IsNullOrWhiteSpace(statement.Text))
                {
                    // A SQL Server batch ended by GO 5 runs five times, as sqlcmd and the macOS import run it.
                    for (var run = 0; run < Math.Max(statement.Repeat, 1); run++)
                    {
                        yield return (statement.Text, line);
                    }
                }
            }

            if (atEnd)
            {
                yield break;
            }

            line += CountLines(text.AsSpan(position, carryFrom - position));
            pending.Clear();

            // The splitter starts every chunk at ';', so a MySQL DELIMITER set in an earlier chunk is said again in front.
            if (dialect.SupportsDelimiterDirective && LastDelimiter(text.AsSpan(0, carryFrom)) is { } delimiter && delimiter != ";")
            {
                pending.Append("DELIMITER ").Append(delimiter).Append('\n');
                line--;
            }

            pending.Append(text, carryFrom, text.Length - carryFrom);
        }
    }

    /// <summary>A transaction statement standing alone, as dumps write them; a block that opens with BEGIN is not one.</summary>
    public static bool IsTransactionControl(string sql) => TransactionControl().IsMatch(sql.AsSpan().Trim().TrimEnd(';').TrimEnd());

    private static string? LastDelimiter(ReadOnlySpan<char> text)
    {
        string? last = null;
        foreach (var match in DelimiterLine().EnumerateMatches(text))
        {
            var directive = text.Slice(match.Index, match.Length).Trim();
            last = directive["DELIMITER".Length..].Trim().ToString();
        }

        return last;
    }

    private static int CountLines(ReadOnlySpan<char> text) => text.Count('\n');

    private static string Snippet(string sql) => sql.Length > 200 ? string.Concat(sql.AsSpan(0, 200), "...") : sql;

    private static async Task RunControlAsync(IQueryChannel channel, string sql, CancellationToken cancellationToken)
    {
        await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(), cancellationToken))
        {
            if (!result.Succeeded)
            {
                throw new StatementFailedException(new SqlImportError(sql, 0, result.Error!));
            }
        }
    }

    /// <summary>Ending or restoring after a failure must not hide the failure itself, so its own error is returned instead.</summary>
    private static async Task<string?> TryRunControlAsync(IQueryChannel channel, string sql)
    {
        try
        {
            await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(), CancellationToken.None))
            {
                if (!result.Succeeded)
                {
                    return result.Error;
                }
            }

            return null;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return ex.Message;
        }
    }

    [GeneratedRegex(@"^(?:(?:BEGIN|START)(?:\s+(?:TRANSACTION|WORK|TRAN|DEFERRED|IMMEDIATE|EXCLUSIVE))?(?:\s+TRANSACTION)?|(?:COMMIT|END)(?:\s+(?:TRANSACTION|WORK|TRAN))?)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TransactionControl();

    [GeneratedRegex(@"^[ \t]*DELIMITER[ \t]+\S+", RegexOptions.IgnoreCase | RegexOptions.Multiline | RegexOptions.CultureInvariant)]
    private static partial Regex DelimiterLine();

    private sealed class StatementFailedException(SqlImportError error) : Exception(error.Message)
    {
        public SqlImportError Error { get; } = error;
    }
}

/// <summary>
/// The statements that open and end a transaction and turn foreign key checks off and on, per engine, as the macOS
/// drivers supply them. A null means the engine has no such statement, and the import runs without it.
/// </summary>
public sealed record SqlImportStatements(string? Begin, string? Commit, string? Rollback, string? ForeignKeysOff, string? ForeignKeysOn)
{
    private static readonly SqlImportStatements None = new(null, null, null, null, null);

    // Setting the role takes a superuser or a SET grant, and a bare refusal aborts the transaction; the block swallows it.
    private static string PostgresRole(string value) =>
        "DO $$ BEGIN SET session_replication_role = " + value + "; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$";

    public bool SupportsTransactions => Commit is not null;

    public static SqlImportStatements For(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => new("BEGIN", "COMMIT", "ROLLBACK", PostgresRole("replica"), PostgresRole("DEFAULT")),
        DatabaseEngine.CockroachDb or DatabaseEngine.Redshift or DatabaseEngine.PGlite => new("BEGIN", "COMMIT", "ROLLBACK", null, null),
        DatabaseEngine.MySql or DatabaseEngine.MariaDb or DatabaseEngine.TiDb or DatabaseEngine.OceanBase => new("START TRANSACTION", "COMMIT", "ROLLBACK", "SET FOREIGN_KEY_CHECKS=0", "SET FOREIGN_KEY_CHECKS=1"),
        DatabaseEngine.SqlServer => new("BEGIN TRANSACTION", "COMMIT TRANSACTION", "ROLLBACK TRANSACTION", null, null),
        DatabaseEngine.Sqlite => new("BEGIN", "COMMIT", "ROLLBACK", "PRAGMA foreign_keys = OFF", "PRAGMA foreign_keys = ON"),
        DatabaseEngine.DuckDb or DatabaseEngine.Snowflake => new("BEGIN TRANSACTION", "COMMIT", "ROLLBACK", null, null),

        // Oracle opens a transaction with the first change, so there is nothing to send before it.
        DatabaseEngine.Oracle => new(null, "COMMIT", "ROLLBACK", null, null),
        _ => None,
    };
}
