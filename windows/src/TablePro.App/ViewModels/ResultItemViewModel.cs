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

    public string Title => IsError ? "Error" : Result is null ? $"Statement {Index}" : $"Result {Index}";

    public string Summary
    {
        get
        {
            var elapsed = FormatElapsed(Statement.Elapsed);
            if (IsError)
            {
                return $"Failed after {elapsed}";
            }

            if (Result is null)
            {
                return Statement.RecordsAffected >= 0
                    ? string.Create(CultureInfo.CurrentCulture, $"{Statement.RecordsAffected:N0} rows affected · {elapsed}")
                    : $"Done · {elapsed}";
            }

            var rows = string.Create(CultureInfo.CurrentCulture, $"{Result.RowCount:N0} rows");
            return Result.IsTruncated ? $"{rows} (limit reached, more on the server) · {elapsed}" : $"{rows} · {elapsed}";
        }
    }

    public static string FormatElapsed(TimeSpan elapsed) => elapsed.TotalMilliseconds switch
    {
        < 1 => "<1 ms",
        < 1000 => string.Create(CultureInfo.CurrentCulture, $"{elapsed.TotalMilliseconds:N0} ms"),
        < 60_000 => string.Create(CultureInfo.CurrentCulture, $"{elapsed.TotalSeconds:N2} s"),
        _ => elapsed.ToString(@"m\:ss", CultureInfo.CurrentCulture),
    };
}
