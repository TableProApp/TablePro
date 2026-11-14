namespace TablePro.Interop;

public sealed partial class DatabaseSession
{
    // The table's columns as the server defines them now, for a CSV import into it.
    public async Task<CsvImport> OpenCsvImportAsync(TableName table, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        var import = await CoreCall.RunAsync(
                token => Handle.OpenCsvImport(Mapping.Table(table), token),
                cancellationToken)
            .ConfigureAwait(false);
        return new CsvImport(import);
    }
}
