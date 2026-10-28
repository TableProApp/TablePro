using System.Text.Json;

namespace TablePro.Drivers.Beancount;

/// <summary>Reads what a backend knows about a ledger.</summary>
internal interface IBeancountProjectionSource
{
    Task<BeancountBackendResult> ReadAsync(string ledgerPath, BeancountSourceGraph graph, CancellationToken cancellationToken);
}

/// <summary>Projects a ledger by running Beancount's own loader once and reading the JSON it prints.</summary>
internal sealed class PythonBackend(BeancountBackend backend, IProcessRunner runner, bool runLedgerPlugins, string version) : IBeancountProjectionSource
{
    /// <summary>
    /// Python writes pipes in the ANSI code page unless told otherwise, which would mangle a non-ASCII error message,
    /// and the plugin switch reaches the script through its environment.
    /// </summary>
    public static Dictionary<string, string> Environment(bool runLedgerPlugins) => new(StringComparer.Ordinal)
    {
        ["PYTHONUTF8"] = "1",
        ["PYTHONIOENCODING"] = "utf-8",
        ["TABLEPRO_BEANCOUNT_RUN_LEDGER_PLUGINS"] = runLedgerPlugins ? "1" : "0",
    };

    public async Task<BeancountBackendResult> ReadAsync(string ledgerPath, BeancountSourceGraph graph, CancellationToken cancellationToken)
    {
        var details = BeancountSourceReaders.ReadDetails(graph);
        var directives = BeancountSourceReaders.ReadDirectives(graph);

        // "-" reads the program from standard input; the ledger path is then sys.argv[1], as with -c on macOS.
        var output = await runner.RunAsync(
            backend.Spec(["-", ledgerPath], Environment(runLedgerPlugins), PythonProjectionScript.Source),
            cancellationToken);
        if (output.ExitCode != 0)
        {
            var message = output.StandardError.Trim();
            throw new BeancountException(message.Length > 0 ? message : "Python Beancount projection failed");
        }

        var tables = Parse(output.StandardOutput);
        var postings = Table(tables, "postings");
        var rows = new BeancountProjectionRows
        {
            Transactions = Table(tables, "transactions"),
            Postings = postings,
            Accounts = Table(tables, "accounts"),
            Prices = Table(tables, "prices"),
            Balances = Table(tables, "balances"),
            BalanceAssertions = BeancountRowEnrichment.BalancesWithDetails(Table(tables, "balance_assertions"), details.Balances, postings),
            Commodities = Table(tables, "commodities"),
            Documents = Table(tables, "documents"),
            Notes = BeancountRowEnrichment.NotesWithDetails(Table(tables, "notes"), details.Notes),
            Events = Table(tables, "events"),
            Pads = Table(tables, "pads"),
            Closes = Table(tables, "closes"),
            Queries = directives.Queries,
            Custom = directives.Custom,
            Directives = Table(tables, "directives"),
            Diagnostics = Table(tables, "diagnostics"),
        };
        return new BeancountBackendResult(rows, version);
    }

    internal static LedgerRow Parse(byte[] json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return LedgerValues.FromJson(document.RootElement) as LedgerRow
                ?? throw new BeancountException("Invalid Python Beancount JSON output");
        }
        catch (JsonException ex)
        {
            throw new BeancountException("Invalid Python Beancount JSON output", ex);
        }
    }

    private static List<LedgerRow> Table(LedgerRow tables, string name) => LedgerValues.Rows(tables.Get(name));
}
