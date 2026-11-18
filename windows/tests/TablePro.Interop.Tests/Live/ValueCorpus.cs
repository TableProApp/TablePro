using System.Text.Json;

namespace TablePro.Interop.Tests.Live;

internal sealed record CorpusValue(string Sql, string? Shows, string? Edited);

internal sealed record CorpusColumn(string Column, IReadOnlyList<string>? Setup, IReadOnlyList<CorpusValue> Values, string? Only);

// The value corpus the core's conformance suites read, in core/crates/test-support/corpus, copied beside the tests.
internal static class ValueCorpus
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static IReadOnlyList<CorpusColumn> Load(string file, string? flavour = null)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "corpus", file + ".json");
        var corpus = JsonSerializer.Deserialize<CorpusFile>(File.ReadAllText(path), Options)
            ?? throw new InvalidDataException($"{path} holds no corpus.");
        return [.. corpus.Columns.Where(column => column.Only is null || column.Only == flavour)];
    }

    private sealed record CorpusFile(IReadOnlyList<CorpusColumn> Columns);
}
