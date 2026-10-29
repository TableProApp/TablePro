using System.Globalization;
using TablePro.App.Controls.DataGrid;
using TablePro.Core.Results;

namespace TablePro.App.ViewModels;

/// <summary>One result set, or one statement's outcome when it returned no rows.</summary>
public sealed class ResultItemViewModel
{
    public ResultItemViewModel(StatementResult statement, ResultSet? result, int index)
    {
        Statement = statement;
        Result = result;
        Index = index;
        Source = result is null ? null : new ResultGridSource(result);
    }

    public StatementResult Statement { get; }

    public ResultSet? Result { get; }

    public int Index { get; }

    public IGridSource? Source { get; }

    public bool HasRows => Result is not null;

    public bool IsError => !Statement.Succeeded;

    public string Title => IsError
        ? Strings.Get("Common/Error")
        : Result is null ? Strings.Format("Query/StatementTabTitle", Index) : Strings.Format("Query/ResultTabTitle", Index);

    public string Summary
    {
        get
        {
            var elapsed = FormatElapsed(Statement.Elapsed);
            if (IsError)
            {
                return Strings.Format("Query/FailedAfter", elapsed);
            }

            if (Result is null)
            {
                return Statement.RecordsAffected >= 0
                    ? Strings.Plural("Query/RowsAffected", Statement.RecordsAffected, elapsed)
                    : Strings.Format("Query/DoneAfter", elapsed);
            }

            return Result.IsTruncated
                ? Strings.Plural("Query/RowsTruncated", Result.RowCount, elapsed)
                : Strings.Plural("Query/RowsReturned", Result.RowCount, elapsed);
        }
    }

    public static string FormatElapsed(TimeSpan elapsed) => elapsed.TotalMilliseconds switch
    {
        < 1 => Strings.Get("Query/ElapsedUnderOneMillisecond"),
        < 1000 => Strings.Format("Query/ElapsedMilliseconds", elapsed.TotalMilliseconds),
        < 60_000 => Strings.Format("Query/ElapsedSeconds", elapsed.TotalSeconds),
        _ => elapsed.ToString(@"m\:ss", CultureInfo.CurrentCulture),
    };
}
