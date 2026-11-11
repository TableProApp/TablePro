using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model;

public sealed class RunResult(int setIndex, IReadOnlyList<ResultColumn> columns)
{
    public int SetIndex { get; } = setIndex;

    public IReadOnlyList<ResultColumn> Columns { get; } = columns;

    public long Rows { get; internal set; }

    // Every row the statement produced, where the engine counted past the limit.
    public long? TotalRows { get; internal set; }

    public bool Truncated { get; internal set; }

    // The server stopped the statement, so work it does per row may have run for only part of the rows.
    public bool StoppedOnServer { get; internal set; }

    // Set from ByteLimitReached alone, since a finish carries no limit.
    public long? SizeLimit { get; internal set; }
}

// Each result set of a run in the order it started, labelled "Result {n} ({rows})" as the Linux app lists them.
public sealed class RunResults(string label, string labelMore)
{
    private readonly List<RunResult> _results = [];

    public IReadOnlyList<RunResult> Results => _results;

    public RunResult Add(int setIndex, IReadOnlyList<ResultColumn> columns)
    {
        var result = new RunResult(setIndex, columns);
        _results.Add(result);
        return result;
    }

    // The listed set the event changed, or null.
    public RunResult? Apply(QueryEvent queryEvent)
    {
        switch (queryEvent)
        {
            case QueryEvent.RowsAppended appended when Find(appended.SetIndex) is { } growing:
                growing.Rows = appended.RowCount;
                return growing;
            case QueryEvent.RowLimitReached limit when Find(limit.SetIndex) is { } cut:
                cut.Truncated = true;
                return cut;
            case QueryEvent.ByteLimitReached bytes when Find(bytes.SetIndex) is { } full:
                full.Truncated = true;
                full.SizeLimit = bytes.LimitBytes;
                return full;
            case QueryEvent.ResultSetFinished finished when Find(finished.SetIndex) is { } ended:
                ended.Rows = finished.RowCount;
                ended.TotalRows = finished.TotalRows;
                ended.Truncated |= finished.Truncation != Truncation.Complete;
                ended.StoppedOnServer = finished.Truncation == Truncation.ServerStopped;
                return ended;
            default:
                return null;
        }
    }

    // A set the limit cut short shows the total the engine counted, or its rows with a plus when nobody counted.
    public string Label(RunResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        var position = _results.IndexOf(result) + 1;
        return result switch
        {
            { Truncated: false } => string.Format(CultureInfo.CurrentCulture, label, position, result.Rows),
            { TotalRows: { } total } => string.Format(CultureInfo.CurrentCulture, label, position, total),
            _ => string.Format(CultureInfo.CurrentCulture, labelMore, position, result.Rows),
        };
    }

    private RunResult? Find(int setIndex) => _results.Find(result => result.SetIndex == setIndex);
}
