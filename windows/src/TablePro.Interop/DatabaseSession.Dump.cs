using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A whole database, or one schema of it.
public abstract record DumpScope
{
    private DumpScope()
    {
    }

    public sealed record Database : DumpScope
    {
        public static Database Instance { get; } = new();
    }

    public sealed record Schema(string Name) : DumpScope;
}

// What a dump wrote. Omitted counts values with no SQL literal on the engine, written as NULL. Skipped counts objects
// the catalog could not carry. Unordered counts tables whose foreign keys point at each other.
public sealed record DumpReport(long Tables, long Rows, long Objects, long Omitted, long Skipped, long Unordered);

// What a dump has written so far, reported a few times a second while it runs.
public readonly record struct DumpProgress(long Rows, long TablesDone, long TablesTotal);

public sealed partial class DatabaseSession
{
    // A whole database or schema written to one SQL file. data writes the tables' rows as INSERTs; false writes only
    // their structure. gzip writes the file gzipped, as a .sql.gz. The file appears whole or not at all.
    public async Task<DumpReport> DumpDatabaseAsync(
        DumpScope scope,
        bool data,
        string path,
        bool gzip = false,
        IProgress<DumpProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentException.ThrowIfNullOrEmpty(path);
        Native.DumpScopeArg native = scope switch
        {
            DumpScope.Schema named => new Native.DumpScopeArg.Schema(named.Name),
            _ => new Native.DumpScopeArg.Database(),
        };
        using var counter = new Native.DumpProgress();
        var report = await Reporting(
                counter,
                progress,
                CoreCall.RunAsync(token => Handle.DumpDatabase(native, data, path, gzip, counter, token), cancellationToken))
            .ConfigureAwait(false);
        return new DumpReport(
            Mapping.Count(report.Tables),
            Mapping.Count(report.Rows),
            Mapping.Count(report.Objects),
            Mapping.Count(report.Omitted),
            Mapping.Count(report.Skipped),
            Mapping.Count(report.Unordered));
    }

    private static async Task<Native.DumpReportRecord> Reporting(
        Native.DumpProgress counter,
        IProgress<DumpProgress>? progress,
        Task<Native.DumpReportRecord> dump)
    {
        if (progress is null)
        {
            return await dump.ConfigureAwait(false);
        }

        using var timer = new PeriodicTimer(ProgressInterval);
        var reported = new DumpProgress(-1, -1, -1);
        while (!dump.IsCompleted)
        {
            var tick = timer.WaitForNextTickAsync().AsTask();
            await Task.WhenAny(dump, tick).ConfigureAwait(false);
            var latest = new DumpProgress(
                Mapping.Count(counter.Rows()),
                Mapping.Count(counter.TablesDone()),
                Mapping.Count(counter.TablesTotal()));
            if (latest != reported)
            {
                reported = latest;
                progress.Report(latest);
            }
        }

        return await dump.ConfigureAwait(false);
    }
}
