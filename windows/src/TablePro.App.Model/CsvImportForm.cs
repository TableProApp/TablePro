using System.Text;
using TablePro.Interop;

namespace TablePro.App.Model;

public enum CsvImportState
{
    Reading,
    // The file could not be read under the options; ReadError says why.
    Failed,
    NoRows,
    NothingMapped,
    Ready,
}

public enum CsvColumnNote
{
    // The mapped field's values in the first rows.
    Samples,
    ServerFilled,
    UsesDefault,
    LeftOut,
}

public enum CsvImportEnding
{
    Imported,
    // Refused before anything was sent, or rolled back: the table is as it was.
    NotWritten,
    PartlyWritten,
    // Stopped or cut off before the server answered: the table may hold some of the rows.
    Unknown,
}

// Header is null where the file names none. Sample is the first row's value, null when it has none.
public sealed record CsvField(int Index, string? Header, string? Sample);

public enum CsvSampleKind
{
    Text,
    Empty,
    Null,

    // A NOT NULL column with a default takes its default for the NULL text, as the core imports it.
    Default,
}

// A field's value as the import writes it into the column, which the NULL text and the column's type decide.
public sealed record CsvSample(CsvSampleKind Kind, string Text);

public sealed record CsvColumnLine(ImportColumn Column, int? Field, CsvColumnNote Note, IReadOnlyList<CsvSample> Samples);

public sealed record CsvPreviewSummary(int Fields, int Rows, bool Truncated);

// Text is what Safe Mode's review lists; Shown counts the statements in it.
public sealed record CsvImportReview(string Text, int Shown);

// Rows: imported, or written before the failure. Lines: those the failed statement held. No Error: stopped here.
public sealed record CsvImportReport(CsvImportEnding Ending, long Rows, LineSpan? Lines, CoreError? Error)
{
    public static CsvImportReport Stopped { get; } = new(CsvImportEnding.Unknown, 0, null, null);

    // Rows may have reached the table, so a tab showing it reads its rows again.
    public bool TableChanged => Ending != CsvImportEnding.NotWritten;

    public static CsvImportReport From(CsvImportOutcome outcome)
    {
        ArgumentNullException.ThrowIfNull(outcome);
        return outcome switch
        {
            CsvImportOutcome.Imported imported => new CsvImportReport(
                CsvImportEnding.Imported, imported.Rows, null, null),
            CsvImportOutcome.RolledBack rolledBack => new CsvImportReport(
                CsvImportEnding.NotWritten, 0, rolledBack.Lines, rolledBack.Error),
            CsvImportOutcome.PartlyWritten partly => new CsvImportReport(
                CsvImportEnding.PartlyWritten, partly.WrittenRows, partly.Lines, partly.Error),
            CsvImportOutcome.Unknown unknown => new CsvImportReport(CsvImportEnding.Unknown, 0, null, unknown.Error),
            _ => throw new ArgumentOutOfRangeException(nameof(outcome)),
        };
    }

    public static CsvImportReport Refused(CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        return new CsvImportReport(CsvImportEnding.NotWritten, 0, null, error);
    }
}

// The import dialog's state from the file to the plan: the options, the preview read, and a field per table column.
public sealed class CsvImportForm
{
    public const int SampleCount = 3;
    public const int SampleLength = 40;

    // A whole file's statements can run to megabytes, more than a dialog can lay out.
    public const int ReviewLength = 50_000;

    private readonly int?[] _mapping;
    private int _read;

    public CsvImportForm(IReadOnlyList<ImportColumn> columns, string filePath)
    {
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentException.ThrowIfNullOrEmpty(filePath);
        Columns = columns;
        FilePath = filePath;
        Options = CsvOptions.Default with { Delimiter = DelimiterFor(filePath) };
        _mapping = new int?[columns.Count];
    }

    public IReadOnlyList<ImportColumn> Columns { get; }

    public string FilePath { get; }

    public string FileName => Path.GetFileName(FilePath);

    public CsvOptions Options { get; private set; }

    public CsvPreview? Preview { get; private set; }

    public CoreError? ReadError { get; private set; }

    public bool IsReading { get; private set; }

    // Set while the whole file is planned, which the dialog waits for with Import off.
    public bool IsPlanning { get; set; }

    public IReadOnlyList<CsvField> Fields { get; private set; } = [];

    public IReadOnlyList<int?> Mapping => _mapping;

    public CsvImportState State
    {
        get
        {
            if (IsReading || (Preview is null && ReadError is null))
            {
                return CsvImportState.Reading;
            }

            if (Preview is not { } preview)
            {
                return CsvImportState.Failed;
            }

            if (preview.Rows.Count == 0)
            {
                return CsvImportState.NoRows;
            }

            return _mapping.Any(mapped => mapped is not null) ? CsvImportState.Ready : CsvImportState.NothingMapped;
        }
    }

    public bool CanImport => State == CsvImportState.Ready && !IsPlanning;

    public CsvPreviewSummary? Summary => Preview is { } preview
        ? new CsvPreviewSummary(preview.Headers.Count, preview.Rows.Count, preview.Truncated)
        : null;

    // A .tsv is tab separated by its name; any other file starts as comma separated.
    public static CsvDelimiter DelimiterFor(string filePath) =>
        string.Equals(Path.GetExtension(filePath), ".tsv", StringComparison.OrdinalIgnoreCase)
            ? CsvDelimiter.Tab
            : CsvDelimiter.Comma;

    // The file names the fields, so another delimiter or header choice reads it again. The number names this read.
    public int Read(CsvDelimiter delimiter, bool hasHeader)
    {
        Options = Options with { Delimiter = delimiter, HasHeader = hasHeader };
        IsReading = true;
        return ++_read;
    }

    // False when a later read replaced this one. Suggested has a field per column, as the core suggests them.
    public bool Show(int read, CsvPreview preview, IReadOnlyList<int?> suggested)
    {
        ArgumentNullException.ThrowIfNull(preview);
        ArgumentNullException.ThrowIfNull(suggested);
        if (read != _read)
        {
            return false;
        }

        IsReading = false;
        Preview = preview;
        ReadError = null;
        IReadOnlyList<string> first = preview.Rows.Count > 0 ? preview.Rows[0] : [];
        Fields = [.. preview.Headers.Select((header, index) => new CsvField(
            index,
            string.IsNullOrWhiteSpace(header) ? null : Clip(header),
            index < first.Count && first[index].Length > 0 ? Clip(first[index]) : null))];
        for (var column = 0; column < _mapping.Length; column++)
        {
            Map(column, column < suggested.Count ? suggested[column] : null);
        }

        return true;
    }

    public bool Fail(int read, CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        if (read != _read)
        {
            return false;
        }

        IsReading = false;
        Preview = null;
        ReadError = error;
        Fields = [];
        Array.Clear(_mapping);
        return true;
    }

    // It decides what a field means, not how the file splits, so the preview and the mapping stand.
    public void SetNullText(string text) => Options = Options with { NullText = text ?? string.Empty };

    // A column the server fills takes no field, and a field the file lacks is none.
    public void Map(int column, int? field)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(column, _mapping.Length);
        _mapping[column] = Columns[column].ServerFilled || field is not { } index || index < 0 || index >= Fields.Count
            ? null
            : index;
    }

    // The dialog lists Skip first, then field n at n + 1.
    public int Choice(int column) => _mapping[column] is { } field ? field + 1 : 0;

    public void Choose(int column, int choice) => Map(column, choice > 0 ? choice - 1 : null);

    public CsvColumnLine Line(int column)
    {
        var info = Columns[column];
        var field = _mapping[column];
        var note = info.ServerFilled ? CsvColumnNote.ServerFilled
            : field is not null ? CsvColumnNote.Samples
            : info.HasDefault ? CsvColumnNote.UsesDefault
            : CsvColumnNote.LeftOut;
        return new CsvColumnLine(info, field, note, field is { } index ? Samples(info, index) : []);
    }

    // One line, cut short, so a value fits a list item.
    public static string Clip(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var cut = text.Length > SampleLength;
        var head = cut ? Cut(text, SampleLength) : text;
        var line = new string(head.Select(c => char.IsControl(c) ? ' ' : c).ToArray());
        return cut ? line + "..." : line;
    }

    // Whole statements while they fit, and always the first; one cut short ends in an ellipsis, not a semicolon.
    public static CsvImportReview Review(IReadOnlyList<string> statements, int length = ReviewLength)
    {
        ArgumentNullException.ThrowIfNull(statements);
        ArgumentOutOfRangeException.ThrowIfLessThan(length, 1);
        var text = new StringBuilder();
        var shown = 0;
        foreach (var statement in statements)
        {
            if (shown > 0)
            {
                if (text.Length + 2 + statement.Length + 1 > length)
                {
                    break;
                }

                text.Append("\n\n");
            }

            shown++;
            if (statement.Length + 1 > length)
            {
                text.Append(Cut(statement, length)).Append("...");
                break;
            }

            text.Append(statement).Append(';');
        }

        return new CsvImportReview(text.ToString(), shown);
    }

    private IReadOnlyList<CsvSample> Samples(ImportColumn column, int field) =>
        Preview is not { } preview
            ? []
            : [.. preview.Rows
                .Where(row => field < row.Count)
                .Take(SampleCount)
                .Select(row => Sample(column, row[field]))];

    // The core's rule: the NULL text is an empty value where it is empty and the column takes one, else the default of
    // a NOT NULL column that has one, else NULL.
    private CsvSample Sample(ImportColumn column, string value)
    {
        if (string.Equals(value, Options.NullText, StringComparison.Ordinal))
        {
            if (value.Length == 0 && column.TakesEmpty)
            {
                return new CsvSample(CsvSampleKind.Empty, string.Empty);
            }

            return !column.Nullable && column.HasDefault
                ? new CsvSample(CsvSampleKind.Default, string.Empty)
                : new CsvSample(CsvSampleKind.Null, string.Empty);
        }

        return value.Length == 0
            ? new CsvSample(CsvSampleKind.Empty, string.Empty)
            : new CsvSample(CsvSampleKind.Text, Clip(value));
    }

    // Never between the halves of a surrogate pair.
    private static string Cut(string text, int length) =>
        text[..(char.IsHighSurrogate(text[length - 1]) ? length - 1 : length)];
}
