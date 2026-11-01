using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>Everything a backend produced for one ledger, table by table, before it is written to SQLite.</summary>
internal sealed class BeancountProjectionRows
{
    public List<LedgerRow> Transactions { get; init; } = [];
    public List<LedgerRow> Postings { get; init; } = [];
    public List<LedgerRow> Accounts { get; init; } = [];
    public List<LedgerRow> Prices { get; init; } = [];
    public List<LedgerRow> Balances { get; init; } = [];
    public List<LedgerRow> BalanceAssertions { get; init; } = [];
    public List<LedgerRow> Commodities { get; init; } = [];
    public List<LedgerRow> Documents { get; init; } = [];
    public List<LedgerRow> Notes { get; init; } = [];
    public List<LedgerRow> Events { get; init; } = [];
    public List<LedgerRow> Pads { get; init; } = [];
    public List<LedgerRow> Closes { get; init; } = [];
    public List<LedgerRow> Queries { get; init; } = [];
    public List<LedgerRow> Custom { get; init; } = [];
    public List<LedgerRow> Directives { get; init; } = [];
    public List<LedgerRow> Diagnostics { get; init; } = [];
}

/// <summary>The rows and the name and version of the backend that produced them.</summary>
internal sealed record BeancountBackendResult(BeancountProjectionRows Rows, string BackendVersion);

/// <summary>Merges the source readers' fields into backend rows, and fills what both backends leave to the driver.</summary>
internal static class BeancountRowEnrichment
{
    private const char KeySeparator = '\u001F';

    /// <summary>Pairs each note with the next unused source note of the same date, account and comment.</summary>
    public static List<LedgerRow> NotesWithDetails(List<LedgerRow> rows, List<LedgerRow> details)
    {
        var pending = Queues(details, NoteKey);
        var enriched = new List<LedgerRow>(rows.Count);
        foreach (var row in rows)
        {
            enriched.Add(pending.TryGetValue(NoteKey(row), out var queue) && queue.TryDequeue(out var detail) ? Merge(row, detail) : row);
        }

        return enriched;
    }

    /// <summary>
    /// Adds each assertion's source tolerance and the difference between what was booked before its date and what it
    /// expects. An assertion holds for the start of its date, so its booked side is the running total of every earlier
    /// posting on that account and commodity.
    /// </summary>
    public static List<LedgerRow> BalancesWithDetails(List<LedgerRow> rows, List<LedgerRow> details, List<LedgerRow> postings)
    {
        var pending = Queues(details, BalanceKey);
        var history = BookedHistory(postings);
        var enriched = new List<LedgerRow>(rows.Count);
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("date")) is not { } date
                || LedgerValues.Text(row.Get("account")) is not { } account
                || row.Get("amount") is not LedgerRow amount
                || LedgerValues.Text(amount.Get("number")) is not { } expectedText
                || LedgerValues.Text(amount.Get("currency")) is not { } currency
                || !LedgerValues.TryParseDecimal(expectedText, out var expected))
            {
                enriched.Add(row);
                continue;
            }

            var result = new LedgerRow(row, StringComparer.Ordinal);
            if (pending.TryGetValue(Key(date, account, currency), out var queue) && queue.TryDequeue(out var detail))
            {
                foreach (var (key, value) in detail)
                {
                    result[key] = value;
                }
            }

            var booked = history.TryGetValue((account, currency), out var series) ? series.TotalBefore(date) : 0m;
            result["difference_amount"] = LedgerValues.NormalizedText(booked - expected);
            result["difference_currency"] = currency;
            enriched.Add(result);
        }

        return enriched;
    }

    /// <summary>rledger reports tags, links and metadata on posting rows, so a transaction without them takes its first posting's.</summary>
    public static List<LedgerRow> TransactionsWithPostingDetails(List<LedgerRow> transactions, List<LedgerRow> postings)
    {
        string[] detailKeys = ["tags", "links", "_entry_meta"];
        var postingDetails = new Dictionary<string, LedgerRow>(StringComparer.Ordinal);
        foreach (var posting in postings)
        {
            if (RowIdentifier(posting.Get("transaction_id")) is { } identifier)
            {
                postingDetails.TryAdd(identifier, posting);
            }
        }

        var enriched = new List<LedgerRow>(transactions.Count);
        foreach (var transaction in transactions)
        {
            if (RowIdentifier(transaction.Get("id")) is not { } identifier || !postingDetails.TryGetValue(identifier, out var details))
            {
                enriched.Add(transaction);
                continue;
            }

            var result = new LedgerRow(transaction, StringComparer.Ordinal);
            foreach (var key in detailKeys)
            {
                if (result.Get(key) is null && details.TryGetValue(key, out var value))
                {
                    result[key] = value;
                }
            }

            enriched.Add(result);
        }

        return enriched;
    }

    /// <summary>
    /// rledger's <c>#entries</c> row for a pad carries no accounts, so they come from its own rendering of each pad,
    /// matched by position and checked by date. A pad that cannot be matched becomes a diagnostic, not a guess.
    /// </summary>
    public static (List<LedgerRow> Rows, List<LedgerRow> Diagnostics) Pads(List<LedgerRow> entries, IReadOnlyList<string> directives)
    {
        var rendered = new List<string>();
        foreach (var directive in directives)
        {
            if (PadRendering(directive) is { } line)
            {
                rendered.Add(line);
            }
        }

        var rows = new List<LedgerRow>();
        var diagnostics = new List<LedgerRow>();
        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index];
            if (LedgerValues.Text(entry.Get("date")) is not { } date)
            {
                diagnostics.Add(PadDiagnostic(entry, BeancountStrings.Get("Beancount/PadNoDate")));
                continue;
            }

            if (index >= rendered.Count || PadDirective(rendered[index]) is not { } printed || printed.Date != date)
            {
                diagnostics.Add(PadDiagnostic(entry, BeancountStrings.Get("Beancount/PadUnmatched")));
                continue;
            }

            var row = new LedgerRow(entry, StringComparer.Ordinal)
            {
                ["account"] = printed.Account,
                ["source_account"] = printed.SourceAccount,
            };
            rows.Add(row);
        }

        return (rows, diagnostics);
    }

    public static (string Date, string Account, string SourceAccount)? PadDirective(string rendering)
    {
        var line = FirstLine(rendering);
        if (line is null)
        {
            return null;
        }

        var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return fields.Length == 4 && fields[1] == "pad" ? (fields[0], fields[2], fields[3]) : null;
    }

    public static LedgerRow PadDiagnostic(LedgerRow? entry, string message)
    {
        var diagnostic = new LedgerRow(StringComparer.Ordinal)
        {
            ["severity"] = "warning",
            ["phase"] = "projection",
            ["message"] = message,
        };
        if (entry is null)
        {
            return diagnostic;
        }

        if (LedgerValues.Text(entry.Get("filename")) is { } file)
        {
            diagnostic["file"] = file;
        }

        if (LedgerValues.Integer(entry.Get("lineno")) is { } line)
        {
            diagnostic["line"] = line;
        }

        return diagnostic;
    }

    private static string? PadRendering(string directive)
    {
        var line = FirstLine(directive);
        if (line is null)
        {
            return null;
        }

        var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return fields.Length >= 2 && fields[1] == "pad" ? line : null;
    }

    private static string? FirstLine(string text)
    {
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            return line;
        }

        return null;
    }

    private static Dictionary<(string, string), BookedSeries> BookedHistory(List<LedgerRow> postings)
    {
        var buckets = new Dictionary<(string, string), List<(string Date, decimal Number)>>();
        foreach (var posting in postings)
        {
            if (LedgerValues.Text(posting.Get("account")) is not { } account
                || LedgerValues.Text(posting.Get("currency")) is not { } currency
                || LedgerValues.Text(posting.Get("date")) is not { } date
                || !LedgerValues.TryParseDecimal(LedgerValues.Text(posting.Get("number")), out var number))
            {
                continue;
            }

            if (!buckets.TryGetValue((account, currency), out var bucket))
            {
                buckets[(account, currency)] = bucket = [];
            }

            bucket.Add((date, number));
        }

        var history = new Dictionary<(string, string), BookedSeries>(buckets.Count);
        foreach (var (key, entries) in buckets)
        {
            entries.Sort(static (a, b) => string.CompareOrdinal(a.Date, b.Date));
            var dates = new string[entries.Count];
            var running = new decimal[entries.Count];
            var total = 0m;
            for (var i = 0; i < entries.Count; i++)
            {
                total += entries[i].Number;
                dates[i] = entries[i].Date;
                running[i] = total;
            }

            history[key] = new BookedSeries(dates, running);
        }

        return history;
    }

    private static Dictionary<string, Queue<LedgerRow>> Queues(List<LedgerRow> details, Func<LedgerRow, string> key)
    {
        var pending = new Dictionary<string, Queue<LedgerRow>>(StringComparer.Ordinal);
        foreach (var detail in details)
        {
            var k = key(detail);
            if (!pending.TryGetValue(k, out var queue))
            {
                pending[k] = queue = new Queue<LedgerRow>();
            }

            queue.Enqueue(detail);
        }

        return pending;
    }

    private static LedgerRow Merge(LedgerRow row, LedgerRow detail)
    {
        var merged = new LedgerRow(row, StringComparer.Ordinal);
        foreach (var (key, value) in detail)
        {
            merged[key] = value;
        }

        return merged;
    }

    private static string NoteKey(LedgerRow row) =>
        Key(LedgerValues.Text(row.Get("date")), LedgerValues.Text(row.Get("account")), LedgerValues.Text(row.Get("comment")));

    private static string BalanceKey(LedgerRow row) =>
        Key(LedgerValues.Text(row.Get("date")), LedgerValues.Text(row.Get("account")), LedgerValues.Text(row.Get("currency")));

    private static string Key(string? a, string? b, string? c) => string.Concat(a, KeySeparator.ToString(), b, KeySeparator.ToString(), c);

    private static string? RowIdentifier(object? value) => value switch
    {
        string s => s,
        long or int or decimal or double => LedgerValues.Text(value),
        _ => null,
    };

    /// <summary>A running total per date, binary-searched per assertion instead of rescanning every posting.</summary>
    private sealed class BookedSeries(string[] dates, decimal[] running)
    {
        public decimal TotalBefore(string date)
        {
            int low = 0, high = dates.Length;
            while (low < high)
            {
                var middle = (low + high) / 2;
                if (string.CompareOrdinal(dates[middle], date) < 0)
                {
                    low = middle + 1;
                }
                else
                {
                    high = middle;
                }
            }

            return low == 0 ? 0m : running[low - 1];
        }
    }
}
