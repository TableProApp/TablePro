using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum CsvDelimiter
{
    Comma,
    Semicolon,
    Tab,
    Pipe,
}

// NullText: a field holding exactly this reads as NULL; empty by default, as every export writes NULL.
public sealed record CsvOptions(CsvDelimiter Delimiter, bool HasHeader, string NullText)
{
    public static CsvOptions Default { get; } = new(CsvDelimiter.Comma, HasHeader: true, NullText: string.Empty);
}

// Headers are empty strings when the file has none, one per field of the widest row.
public sealed record CsvPreview(IReadOnlyList<string> Headers, IReadOnlyList<IReadOnlyList<string>> Rows, bool Truncated);

// ServerFilled: a generated column or an identity that refuses a value; no field is ever mapped to it.
public sealed record ImportColumn(string Name, string TypeName, bool Nullable, bool HasDefault, bool ServerFilled);

// Line counts the header as line 1, as a spreadsheet shows it. Reason is the code a cell edit refused alike has.
public sealed record CsvRowFault(long Line, string Column, string Text, string Reason);

public sealed record LineSpan(long First, long Last);

public abstract record CsvImportCheck
{
    private CsvImportCheck()
    {
    }

    // Statements are the SQL the rows write as, which Safe Mode shows before a confirmed run.
    public sealed record Ready(long Rows, IReadOnlyList<string> Statements, SaveGate Gate) : CsvImportCheck;

    public sealed record Empty : CsvImportCheck
    {
        public static Empty Instance { get; } = new();
    }

    public sealed record RowRefused(CsvRowFault Fault) : CsvImportCheck;
}

public abstract record CsvImportOutcome
{
    private CsvImportOutcome()
    {
    }

    public sealed record Imported(long Rows) : CsvImportOutcome;

    // Nothing was written. Lines are those of the statement that failed, when the engine said which.
    public sealed record RolledBack(CoreError Error, LineSpan? Lines) : CsvImportOutcome;

    // The engine has no transaction to undo it: WrittenRows rows before the failed lines stay in the table.
    public sealed record PartlyWritten(CoreError Error, long WrittenRows, LineSpan? Lines) : CsvImportOutcome;

    // Stopped, or the connection went before the server answered: the table may hold some rows or none.
    public sealed record Unknown(CoreError Error) : CsvImportOutcome;
}

// A table's columns as a CSV import writes them; Run writes the import planned last, once.
public sealed class CsvImport : IDisposable
{
    private readonly Native.CsvImport _import;

    internal CsvImport(Native.CsvImport import)
    {
        _import = import;
        Columns = [.. import.Columns().Select(column => new ImportColumn(
            column.Name,
            column.TypeName,
            column.Nullable,
            column.HasDefault,
            column.ServerFilled))];
    }

    public IReadOnlyList<ImportColumn> Columns { get; }

    // The first rows, enough to judge the delimiter and the header.
    public async Task<CsvPreview> PreviewAsync(string path, CsvOptions options, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(options);
        cancellationToken.ThrowIfCancellationRequested();
        var native = Options(options);
        var preview = await CoreCall.RunAsync(() => _import.Preview(path, native))
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        return new CsvPreview([.. preview.Headers], [.. preview.Rows.Select(row => (IReadOnlyList<string>)[.. row])], preview.Truncated);
    }

    // Per column, the field whose header names it, in any case; null leaves the column to its default.
    public IReadOnlyList<int?> SuggestMapping(IReadOnlyList<string> headers)
    {
        ArgumentNullException.ThrowIfNull(headers);
        string[] native = [.. headers];
        return [.. CoreCall.Run(() => _import.SuggestMapping(native)).Select(field => field is { } index ? (int?)checked((int)index) : null)];
    }

    // Reads the whole file. Mapping has one field per column, null for none; the plan replaces any before it.
    public async Task<CsvImportCheck> PlanAsync(
        string path,
        CsvOptions options,
        IReadOnlyList<int?> mapping,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(mapping);
        cancellationToken.ThrowIfCancellationRequested();
        var native = Options(options);
        uint?[] fields = [.. mapping.Select(field => field is { } index ? (uint?)checked((uint)index) : null)];
        var check = await CoreCall.RunAsync(() => _import.Plan(path, native, fields))
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        return check switch
        {
            Native.CsvImportCheck.Ready ready => new CsvImportCheck.Ready(
                Mapping.Count(ready.Rows),
                [.. ready.Statements],
                Mapping.Gate(ready.Gate)),
            Native.CsvImportCheck.RowRefused refused => new CsvImportCheck.RowRefused(new CsvRowFault(
                Mapping.Count(refused.Fault.Line),
                refused.Fault.Column,
                refused.Fault.Text,
                refused.Fault.Reason)),
            _ => CsvImportCheck.Empty.Instance,
        };
    }

    // Confirmed says Safe Mode's question was answered; a level saved since the plan refuses before anything is sent.
    public async Task<CsvImportOutcome> RunAsync(bool confirmed, CancellationToken cancellationToken = default)
    {
        var outcome = await CoreCall.RunAsync(token => _import.Run(confirmed, token), cancellationToken).ConfigureAwait(false);
        return outcome switch
        {
            Native.CsvImportOutcome.Imported imported => new CsvImportOutcome.Imported(Mapping.Count(imported.Rows)),
            Native.CsvImportOutcome.RolledBack rolledBack => new CsvImportOutcome.RolledBack(
                Mapping.Error(rolledBack.Error),
                Lines(rolledBack.Lines)),
            Native.CsvImportOutcome.PartlyWritten partly => new CsvImportOutcome.PartlyWritten(
                Mapping.Error(partly.Error),
                Mapping.Count(partly.WrittenRows),
                Lines(partly.Lines)),
            Native.CsvImportOutcome.Unknown unknown => new CsvImportOutcome.Unknown(Mapping.Error(unknown.Error)),
            _ => throw new InvalidOperationException("The core reported an import outcome this build does not know."),
        };
    }

    public void Dispose() => _import.Dispose();

    private static LineSpan? Lines(Native.LineSpan? lines) =>
        lines is { } span ? new LineSpan(Mapping.Count(span.First), Mapping.Count(span.Last)) : null;

    private static Native.CsvReadOptions Options(CsvOptions options) => new(
        options.Delimiter switch
        {
            CsvDelimiter.Semicolon => Native.CsvDelimiterTag.Semicolon,
            CsvDelimiter.Tab => Native.CsvDelimiterTag.Tab,
            CsvDelimiter.Pipe => Native.CsvDelimiterTag.Pipe,
            _ => Native.CsvDelimiterTag.Comma,
        },
        options.HasHeader,
        options.NullText ?? string.Empty);
}
