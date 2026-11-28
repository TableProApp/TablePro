using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum SqlImportErrorPolicy
{
    // Stop at the first statement that fails, as psql with ON_ERROR_STOP does.
    Stop,

    // Note it and go on, as mysql --force does.
    Continue,
}

// OneTransaction runs the whole file as one transaction, on an engine whose DDL rolls back. Only with Stop.
public sealed record SqlImportOptions(SqlImportErrorPolicy OnError, bool OneTransaction)
{
    public static SqlImportOptions Default { get; } = new(SqlImportErrorPolicy.Stop, OneTransaction: false);
}

// What a SQL file import has done so far, reported a few times a second while it runs. BytesRead is the file read
// before any read ahead.
public readonly record struct SqlImportProgress(long BytesRead, long Statements, long Failed);

public abstract record SqlImportEnd
{
    private SqlImportEnd()
    {
    }

    public sealed record Completed : SqlImportEnd
    {
        public static Completed Instance { get; } = new();
    }

    // A statement failed and the import stopped there.
    public sealed record Stopped : SqlImportEnd
    {
        public static Stopped Instance { get; } = new();
    }

    public sealed record Cancelled : SqlImportEnd
    {
        public static Cancelled Instance { get; } = new();
    }

    // The file could not be read; Code is the read error's.
    public sealed record FileError(string Code, string Message) : SqlImportEnd;

    // The editor session itself failed, as on a lost connection.
    public sealed record SessionError(CoreError Error) : SqlImportEnd;
}

public abstract record SqlImportFault
{
    private SqlImportFault()
    {
    }

    // The server refused the statement.
    public sealed record Statement(CoreError Error) : SqlImportFault;

    // A psql meta-command nothing here runs.
    public sealed record ClientCommand(string Command) : SqlImportFault;

    // A COPY FROM stdin in the binary format, whose rows a script cannot hold.
    public sealed record CopyBinary : SqlImportFault;

    // The file ended the transaction the import ran it in.
    public sealed record FileEndsTransaction : SqlImportFault;
}

// Line counts from 1 at the file's start.
public sealed record SqlImportFailure(long Line, string Statement, SqlImportFault Fault);

public abstract record TransactionOutcome
{
    private TransactionOutcome()
    {
    }

    // Every statement committed as it ran, or the file's own transactions decided.
    public sealed record AsWritten : TransactionOutcome
    {
        public static AsWritten Instance { get; } = new();
    }

    public sealed record Committed : TransactionOutcome
    {
        public static Committed Instance { get; } = new();
    }

    public sealed record RolledBack : TransactionOutcome
    {
        public static RolledBack Instance { get; } = new();
    }

    // The file left a transaction of its own open, and it was rolled back.
    public sealed record OpenRolledBack : TransactionOutcome
    {
        public static OpenRolledBack Instance { get; } = new();
    }

    // The commit or rollback failed, so what the server kept is unknown.
    public sealed record Unknown(CoreError Error) : TransactionOutcome;
}

// Statements counts those the server ran. Skipped counts client-only lines and the file's own transaction statements
// inside the import's transaction.
public sealed record SqlImportReport(
    SqlImportEnd End,
    long Statements,
    long Skipped,
    long Failed,
    IReadOnlyList<SqlImportFailure> Failures,
    TransactionOutcome Transaction,
    TimeSpan Elapsed);

public sealed partial class DatabaseSession
{
    // Run a SQL file on an editor session of the import's own, a statement at a time, as the engine's own client would.
    // The file is read a piece at a time and never held whole.
    public async Task<SqlImportReport> ImportSqlFileAsync(
        string path,
        SqlImportOptions options,
        IProgress<SqlImportProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(options);
        var native = new Native.SqlImportOptionsArg(
            options.OnError == SqlImportErrorPolicy.Continue
                ? Native.SqlImportErrorPolicyTag.Continue
                : Native.SqlImportErrorPolicyTag.Stop,
            options.OneTransaction);
        using var counter = new Native.SqlImportProgress();
        var report = await Reporting(
                counter,
                progress,
                CoreCall.RunAsync(token => Handle.ImportSqlFile(path, native, counter, token), cancellationToken))
            .ConfigureAwait(false);
        return new SqlImportReport(
            End(report.End),
            Mapping.Count(report.Statements),
            Mapping.Count(report.Skipped),
            Mapping.Count(report.Failed),
            [.. report.Failures.Select(Failure)],
            Transaction(report.Transaction),
            TimeSpan.FromMilliseconds(report.ElapsedMs));
    }

    private static async Task<Native.SqlImportReportRecord> Reporting(
        Native.SqlImportProgress counter,
        IProgress<SqlImportProgress>? progress,
        Task<Native.SqlImportReportRecord> import)
    {
        if (progress is null)
        {
            return await import.ConfigureAwait(false);
        }

        using var timer = new PeriodicTimer(ProgressInterval);
        var reported = new SqlImportProgress(-1, -1, -1);
        while (!import.IsCompleted)
        {
            var tick = timer.WaitForNextTickAsync().AsTask();
            await Task.WhenAny(import, tick).ConfigureAwait(false);
            var latest = new SqlImportProgress(
                Mapping.Count(counter.BytesRead()),
                Mapping.Count(counter.Statements()),
                Mapping.Count(counter.Failed()));
            if (latest != reported)
            {
                reported = latest;
                progress.Report(latest);
            }
        }

        return await import.ConfigureAwait(false);
    }

    private static SqlImportEnd End(Native.SqlImportEndTag end) => end switch
    {
        Native.SqlImportEndTag.Completed => SqlImportEnd.Completed.Instance,
        Native.SqlImportEndTag.Stopped => SqlImportEnd.Stopped.Instance,
        Native.SqlImportEndTag.Cancelled => SqlImportEnd.Cancelled.Instance,
        Native.SqlImportEndTag.FileError file => new SqlImportEnd.FileError(file.Code, file.Message),
        Native.SqlImportEndTag.SessionError session => new SqlImportEnd.SessionError(Mapping.Error(session.Error)),
        _ => throw new InvalidOperationException("The core reported an import end this build does not know."),
    };

    private static TransactionOutcome Transaction(Native.TransactionOutcomeTag outcome) => outcome switch
    {
        Native.TransactionOutcomeTag.AsWritten => TransactionOutcome.AsWritten.Instance,
        Native.TransactionOutcomeTag.Committed => TransactionOutcome.Committed.Instance,
        Native.TransactionOutcomeTag.RolledBack => TransactionOutcome.RolledBack.Instance,
        Native.TransactionOutcomeTag.OpenRolledBack => TransactionOutcome.OpenRolledBack.Instance,
        Native.TransactionOutcomeTag.Unknown unknown => new TransactionOutcome.Unknown(Mapping.Error(unknown.Error)),
        _ => throw new InvalidOperationException("The core reported a transaction outcome this build does not know."),
    };

    private static SqlImportFailure Failure(Native.SqlImportFailureRecord failure) =>
        new(Mapping.Count(failure.Line), failure.Statement, Fault(failure.Fault));

    private static SqlImportFault Fault(Native.SqlImportFaultTag fault) => fault switch
    {
        Native.SqlImportFaultTag.Statement statement => new SqlImportFault.Statement(Mapping.Error(statement.Error)),
        Native.SqlImportFaultTag.ClientCommand command => new SqlImportFault.ClientCommand(command.Command),
        Native.SqlImportFaultTag.CopyBinary => new SqlImportFault.CopyBinary(),
        Native.SqlImportFaultTag.FileEndsTransaction => new SqlImportFault.FileEndsTransaction(),
        _ => throw new InvalidOperationException("The core reported an import fault this build does not know."),
    };
}
