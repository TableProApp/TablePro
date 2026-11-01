using System.Collections.Concurrent;
using System.Text.Json;
using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>Which columns an rledger answers: a property of the binary, so it is learned once per executable.</summary>
internal sealed class RledgerCapabilities
{
    public static readonly RledgerCapabilities Shared = new();

    public ConcurrentDictionary<string, bool> NoCacheSupport { get; } = new(StringComparer.OrdinalIgnoreCase);

    public ConcurrentDictionary<string, PostingsColumnLevel> PostingsLevels { get; } = new(StringComparer.OrdinalIgnoreCase);

    public ConcurrentDictionary<string, EntriesMetadataColumn> MetadataColumns { get; } = new(StringComparer.OrdinalIgnoreCase);

    public ConcurrentDictionary<string, string> Versions { get; } = new(StringComparer.OrdinalIgnoreCase);
}

internal enum PostingsColumnLevel
{
    Complete,
    Source,
    Core,
}

/// <summary>Where <c>#entries</c> keeps a directive's own metadata: <c>_entry_meta</c> through rledger 0.22, <c>meta</c> from 0.23.</summary>
internal enum EntriesMetadataColumn
{
    EntryMeta,
    Meta,
}

/// <summary>
/// Projects a ledger by asking rledger one BQL query per table. An rledger that does not know a column fails the
/// whole SELECT, so the optional columns are asked for in groups and narrowed until one answers.
/// </summary>
internal sealed class RledgerBackend(BeancountBackend backend, IProcessRunner runner, RledgerCapabilities capabilities) : IBeancountProjectionSource
{
    private const string TransactionsCoreColumns = "id, date, flag, payee, narration, filename, lineno";
    private const string TransactionsCoreQuery = "SELECT " + TransactionsCoreColumns + " FROM #entries WHERE type = 'transaction' ORDER BY id";
    private const string PostingsCoreColumns = "id, date, flag, payee, narration, account, number, currency, cost_number, cost_currency";
    private const string PostingsSourceColumns = "filename, lineno, location, tags, links, _entry_meta, _posting_meta";
    private const string PostingsSemanticColumns = "posting_flag, price, cost_date, cost_label";
    private const string AccountsQuery = "SELECT account, open, currencies, booking FROM #accounts ORDER BY account";
    private const string AccountsCoreQuery = "SELECT account, open, currencies FROM #accounts ORDER BY account";
    private const string PricesQuery = "SELECT date, currency, amount FROM #prices ORDER BY date, currency";
    private const string BalancesQuery = "SELECT account, sum(units(position)) AS balance FROM #postings GROUP BY account ORDER BY account";
    private const string BalanceAssertionsQuery = "SELECT date, account, amount FROM #balances ORDER BY date, account";
    private const string CommoditiesQuery = "SELECT date, name FROM #commodities ORDER BY date, name";
    private const string DocumentsQuery = "SELECT date, account, filename, tags, links FROM #documents ORDER BY date, account";
    private const string NotesQuery = "SELECT date, account, comment FROM #notes ORDER BY date, account";
    private const string EventsQuery = "SELECT date, type, description FROM #events ORDER BY date, type";
    private const string PadsQuery = "SELECT id, date, filename, lineno FROM #entries WHERE type = 'pad' ORDER BY id";
    private const string PadDirectivesQuery = "PRINT FROM FALSE";
    private const string ClosesQuery = "SELECT account, close FROM #accounts WHERE close IS NOT NULL ORDER BY close, account";

    private static readonly PostingsColumnLevel[] WidestFirst = [PostingsColumnLevel.Complete, PostingsColumnLevel.Source, PostingsColumnLevel.Core];

    private string Executable => backend.Executable;

    public async Task<BeancountBackendResult> ReadAsync(string ledgerPath, BeancountSourceGraph graph, CancellationToken cancellationToken)
    {
        var details = BeancountSourceReaders.ReadDetails(graph);
        var sourceDirectives = BeancountSourceReaders.ReadDirectives(graph);

        var transactions = await TransactionRowsAsync(ledgerPath, cancellationToken);
        var postings = await PostingRowsAsync(ledgerPath, cancellationToken);
        var pads = await PadsAsync(ledgerPath, cancellationToken);
        var assertions = BeancountRowEnrichment.BalancesWithDetails(
            await QueryAsync(ledgerPath, BalanceAssertionsQuery, cancellationToken), details.Balances, postings);
        var accounts = await AccountRowsAsync(ledgerPath, cancellationToken);
        var prices = await QueryAsync(ledgerPath, PricesQuery, cancellationToken);
        var balances = await QueryAsync(ledgerPath, BalancesQuery, cancellationToken);
        var commodities = await OptionalAsync(() => QueryAsync(ledgerPath, CommoditiesQuery, cancellationToken));
        var documents = await OptionalAsync(() => QueryAsync(ledgerPath, DocumentsQuery, cancellationToken));
        var notes = BeancountRowEnrichment.NotesWithDetails(await OptionalAsync(() => QueryAsync(ledgerPath, NotesQuery, cancellationToken)), details.Notes);
        var events = await OptionalAsync(() => QueryAsync(ledgerPath, EventsQuery, cancellationToken));
        var closes = await OptionalAsync(() => QueryAsync(ledgerPath, ClosesQuery, cancellationToken));
        var directives = await OptionalAsync(() => EntriesQueryAsync(ledgerPath, DirectivesQuery, cancellationToken));
        var diagnostics = await ValidationDiagnosticsAsync(ledgerPath, cancellationToken);
        diagnostics.AddRange(pads.Diagnostics);

        var rows = new BeancountProjectionRows
        {
            Transactions = BeancountRowEnrichment.TransactionsWithPostingDetails(transactions, postings),
            Postings = postings,
            Accounts = accounts,
            Prices = prices,
            Balances = balances,
            BalanceAssertions = assertions,
            Commodities = commodities,
            Documents = documents,
            Notes = notes,
            Events = events,
            Pads = pads.Rows,
            Closes = closes,
            Queries = sourceDirectives.Queries,
            Custom = sourceDirectives.Custom,
            Directives = directives,
            Diagnostics = diagnostics,
        };
        return new BeancountBackendResult(rows, await VersionAsync(cancellationToken));
    }

    /// <summary>Runs one BQL query and returns rledger's JSON, for the editor's <c>BQL:</c> statements.</summary>
    public async Task<byte[]> QueryJsonAsync(string ledgerPath, string bql, CancellationToken cancellationToken) =>
        await RunAsync(await QueryArgumentsAsync(ledgerPath, bql, cancellationToken), BeancountStrings.Get("Beancount/RustledgerFailed"), allowsNonZeroExit: false, cancellationToken);

    public async Task<string> VersionAsync(CancellationToken cancellationToken)
    {
        if (capabilities.Versions.TryGetValue(Executable, out var cached))
        {
            return cached;
        }

        string version;
        try
        {
            var reported = (await RunAsync(["--version"], BeancountStrings.Get("Beancount/RledgerVersionFailed"), allowsNonZeroExit: false, cancellationToken)).AsSpan();
            var text = System.Text.Encoding.UTF8.GetString(reported).Trim();
            version = text.Length == 0 ? "rledger" : text.StartsWith("rledger ", StringComparison.OrdinalIgnoreCase) ? text : "rledger " + text;
        }
        catch (BeancountException)
        {
            version = "rledger";
        }

        capabilities.Versions[Executable] = version;
        return version;
    }

    private static string TransactionsQuery(EntriesMetadataColumn metadata) =>
        $"SELECT {TransactionsCoreColumns}, tags, links, {Selection(metadata)} FROM #entries WHERE type = 'transaction' ORDER BY id";

    // A directive's own metadata, its entry id and the filename and line the parser recorded come from the backend:
    // reading them back out of the ledger text would be a second, weaker parser that cannot see plugin-made entries.
    private static string DirectivesQuery(EntriesMetadataColumn metadata) =>
        $"SELECT id, type, date, filename, lineno, {Selection(metadata)} FROM #entries WHERE type != 'transaction' ORDER BY id";

    private static string Selection(EntriesMetadataColumn metadata) => metadata == EntriesMetadataColumn.Meta ? "meta AS _entry_meta" : "_entry_meta";

    private static string PostingsQuery(PostingsColumnLevel level) => level switch
    {
        PostingsColumnLevel.Complete => $"SELECT {PostingsCoreColumns}, {PostingsSemanticColumns}, {PostingsSourceColumns} FROM #postings ORDER BY id",
        PostingsColumnLevel.Source => $"SELECT {PostingsCoreColumns}, {PostingsSourceColumns} FROM #postings ORDER BY id",
        _ => $"SELECT {PostingsCoreColumns} FROM #postings ORDER BY id",
    };

    private async Task<List<LedgerRow>> TransactionRowsAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        try
        {
            return await EntriesQueryAsync(ledgerPath, TransactionsQuery, cancellationToken);
        }
        catch (BeancountException)
        {
            return await QueryAsync(ledgerPath, TransactionsCoreQuery, cancellationToken);
        }
    }

    private async Task<List<LedgerRow>> AccountRowsAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        try
        {
            return await QueryAsync(ledgerPath, AccountsQuery, cancellationToken);
        }
        catch (BeancountException)
        {
            return await QueryAsync(ledgerPath, AccountsCoreQuery, cancellationToken);
        }
    }

    private async Task<List<LedgerRow>> PostingRowsAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        var rows = await PostingRowsFromWidestColumnsAsync(ledgerPath, cancellationToken);
        foreach (var row in rows)
        {
            row["transaction_id"] = row.Get("id");
        }

        return rows;
    }

    // Losing the posting semantics must not also cost the source locations and metadata, so the groups narrow one at a time.
    private async Task<List<LedgerRow>> PostingRowsFromWidestColumnsAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        if (capabilities.PostingsLevels.TryGetValue(Executable, out var cached))
        {
            return await QueryAsync(ledgerPath, PostingsQuery(cached), cancellationToken);
        }

        BeancountException? failure = null;
        foreach (var level in WidestFirst)
        {
            try
            {
                var rows = await QueryAsync(ledgerPath, PostingsQuery(level), cancellationToken);
                capabilities.PostingsLevels[Executable] = level;
                return rows;
            }
            catch (BeancountException ex)
            {
                failure = ex;
            }
        }

        throw failure ?? new BeancountException(BeancountStrings.Get("Beancount/RustledgerFailed"));
    }

    private async Task<(List<LedgerRow> Rows, List<LedgerRow> Diagnostics)> PadsAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        var entries = await OptionalAsync(() => QueryAsync(ledgerPath, PadsQuery, cancellationToken));
        if (entries.Count == 0)
        {
            return ([], []);
        }

        try
        {
            var printed = await QueryAsync(ledgerPath, PadDirectivesQuery, cancellationToken);
            var directives = new List<string>(printed.Count);
            foreach (var row in printed)
            {
                if (LedgerValues.Text(row.Get("directive")) is { } directive)
                {
                    directives.Add(directive);
                }
            }

            return BeancountRowEnrichment.Pads(entries, directives);
        }
        catch (BeancountException ex)
        {
            return ([], [BeancountRowEnrichment.PadDiagnostic(null, BeancountStrings.Format("Beancount/PadsUnrendered", ex.Message))]);
        }
    }

    private async Task<List<LedgerRow>> ValidationDiagnosticsAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        try
        {
            var json = await RunAsync(["check", "--no-cache", "-f", "json", ledgerPath], BeancountStrings.Get("Beancount/RustledgerValidationFailed"), allowsNonZeroExit: true, cancellationToken);
            using var document = JsonDocument.Parse(json);
            return LedgerValues.FromJson(document.RootElement) is LedgerRow root && root.Get("diagnostics") is List<object?> list
                ? LedgerValues.Rows(list)
                : [];
        }
        catch (Exception ex) when (ex is BeancountException or JsonException)
        {
            // A validation that does not run leaves the diagnostics table empty rather than failing the connection.
            return [];
        }
    }

    /// <summary>Runs an <c>#entries</c> query against the metadata column this rledger has.</summary>
    private async Task<List<LedgerRow>> EntriesQueryAsync(string ledgerPath, Func<EntriesMetadataColumn, string> bql, CancellationToken cancellationToken)
    {
        var column = await MetadataColumnAsync(ledgerPath, cancellationToken);
        var rows = await QueryAsync(ledgerPath, bql(column), cancellationToken);
        if (column == EntriesMetadataColumn.Meta)
        {
            foreach (var row in rows)
            {
                row["_entry_meta"] = OwnMetadata(row.Get("_entry_meta"));
            }
        }

        return rows;
    }

    // Read from the table's columns: rledger reports a missing column only while evaluating a row, so a trial query
    // against a ledger with no matching entries would answer without error and prove nothing.
    private async Task<EntriesMetadataColumn> MetadataColumnAsync(string ledgerPath, CancellationToken cancellationToken)
    {
        if (capabilities.MetadataColumns.TryGetValue(Executable, out var cached))
        {
            return cached;
        }

        var json = await QueryJsonAsync(ledgerPath, "SELECT * FROM #entries LIMIT 0", cancellationToken);
        var column = RledgerOutput.Columns(json).Contains("meta") ? EntriesMetadataColumn.Meta : EntriesMetadataColumn.EntryMeta;
        capabilities.MetadataColumns[Executable] = column;
        return column;
    }

    /// <summary><c>meta</c> also holds the parser's filename and line and Beancount's <c>__</c> keys, which directive metadata leaves out.</summary>
    internal static object? OwnMetadata(object? value)
    {
        if (value is not LedgerRow metadata)
        {
            return value;
        }

        var own = new LedgerRow(StringComparer.Ordinal);
        foreach (var (key, item) in metadata)
        {
            if (key is not ("filename" or "lineno") && !key.StartsWith("__", StringComparison.Ordinal))
            {
                own[key] = item;
            }
        }

        return own.Count == 0 ? null : own;
    }

    private async Task<List<LedgerRow>> QueryAsync(string ledgerPath, string bql, CancellationToken cancellationToken) =>
        RledgerOutput.Rows(await QueryJsonAsync(ledgerPath, bql, cancellationToken));

    private async Task<List<string>> QueryArgumentsAsync(string ledgerPath, string bql, CancellationToken cancellationToken)
    {
        List<string> arguments = ["query", "-f", "json", "--no-errors"];
        if (await SupportsNoCacheAsync(cancellationToken))
        {
            arguments.Add("--no-cache");
        }

        arguments.Add(ledgerPath);
        arguments.Add(bql);
        return arguments;
    }

    private async Task<bool> SupportsNoCacheAsync(CancellationToken cancellationToken)
    {
        if (capabilities.NoCacheSupport.TryGetValue(Executable, out var cached))
        {
            return cached;
        }

        bool supports;
        try
        {
            var output = await runner.RunAsync(backend.Spec(["query", "--help"]), cancellationToken);
            supports = output.ExitCode == 0
                && (output.StandardOutputText.Contains("--no-cache", StringComparison.Ordinal) || output.StandardError.Contains("--no-cache", StringComparison.Ordinal));
        }
        catch (BeancountException)
        {
            supports = false;
        }

        capabilities.NoCacheSupport[Executable] = supports;
        return supports;
    }

    private async Task<byte[]> RunAsync(IReadOnlyList<string> arguments, string failureMessage, bool allowsNonZeroExit, CancellationToken cancellationToken)
    {
        var output = await runner.RunAsync(backend.Spec(arguments), cancellationToken);
        if (output.ExitCode != 0 && !allowsNonZeroExit)
        {
            var message = output.StandardError.Trim();
            throw new BeancountException(message.Length > 0 ? message : failureMessage);
        }

        return output.StandardOutput;
    }

    /// <summary>A table a backend may not support stays empty instead of failing the whole projection.</summary>
    private static async Task<List<LedgerRow>> OptionalAsync(Func<Task<List<LedgerRow>>> rows)
    {
        try
        {
            return await rows();
        }
        catch (BeancountException)
        {
            return [];
        }
    }
}
