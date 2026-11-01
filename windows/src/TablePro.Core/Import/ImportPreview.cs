namespace TablePro.Core.Import;

/// <summary>
/// The fields of an import file and its first rows, read before the import so the mapping can be checked against
/// real values. The fields' types are inferred from a larger sample than the rows shown.
/// </summary>
/// <param name="Fields">Every field in file order: CSV columns as they stand, JSON keys in the order they first appear.</param>
/// <param name="Rows">The first rows, each aligned to <see cref="Fields"/>.</param>
/// <param name="SampledRows">How many rows the inference read, at most <see cref="ImportTypeInference.SampleSize"/>.</param>
public sealed record ImportPreview(IReadOnlyList<ImportField> Fields, IReadOnlyList<object?[]> Rows, int SampledRows)
{
    public const int DefaultPreviewRows = 10;

    /// <summary>Reads the head of a file. The stream is read only as far as the sample needs.</summary>
    public static async Task<ImportPreview> ReadAsync(
        Stream stream, ImportFileFormat format, CsvImportOptions? csvOptions, int previewRows = DefaultPreviewRows, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        var names = new List<string>();
        var index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var samples = new List<List<object?>>();
        var sampled = new List<IReadOnlyDictionary<string, object?>>();
        var records = 0;
        await foreach (var record in ImportFile.ReadRecordsAsync(stream, format, csvOptions, cancellationToken))
        {
            foreach (var (name, value) in record)
            {
                if (!index.TryGetValue(name, out var column))
                {
                    column = names.Count;
                    index[name] = column;
                    names.Add(name);
                    samples.Add([]);
                }

                samples[column].Add(value);
            }

            if (sampled.Count < previewRows)
            {
                sampled.Add(record);
            }

            if (++records >= ImportTypeInference.SampleSize)
            {
                break;
            }
        }

        var fields = new ImportField[names.Count];
        for (var i = 0; i < fields.Length; i++)
        {
            var values = samples[i];
            var first = values.FirstOrDefault(v => v is not null);
            var type = format == ImportFileFormat.Json
                ? ImportTypeInference.InferJson(values)
                : ImportTypeInference.InferText(values.Select(v => v as string));
            fields[i] = new ImportField(names[i], first is null ? null : Truncate(first is string s ? s : Results.CellFormatter.Format(first is JsonText json ? json.Text : first)), type);
        }

        var rows = new List<object?[]>(sampled.Count);
        foreach (var record in sampled)
        {
            var row = new object?[fields.Length];
            for (var i = 0; i < fields.Length; i++)
            {
                row[i] = record.TryGetValue(fields[i].Name, out var value) ? value is JsonText json ? json.Text : value : null;
            }

            rows.Add(row);
        }

        return new ImportPreview(fields, rows, records);
    }

    /// <summary>A sample is shown on one line beside the field, so a long value is cut as macOS cuts it.</summary>
    private static string Truncate(string value) => value.Length <= 80 ? value : string.Concat(value.AsSpan(0, 79), "…");
}
