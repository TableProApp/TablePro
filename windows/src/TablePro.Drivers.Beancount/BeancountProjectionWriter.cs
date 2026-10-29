using System.Globalization;
using Microsoft.Data.Sqlite;
using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// Writes backend rows into the SQLite tables a Beancount connection shows. The table and column names match the
/// macOS app's, so a query written against a ledger there runs here unchanged.
/// </summary>
internal sealed class BeancountProjectionWriter : IDisposable
{
    internal const string Schema = """
        CREATE TABLE transactions (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            flag TEXT NOT NULL,
            payee TEXT,
            narration TEXT,
            source_file TEXT,
            line INTEGER,
            source_location TEXT
        );
        CREATE TABLE postings (
            id INTEGER PRIMARY KEY,
            transaction_id INTEGER NOT NULL,
            date DATE NOT NULL,
            account TEXT NOT NULL,
            amount TEXT,
            commodity TEXT,
            flag TEXT,
            cost_number TEXT,
            cost_currency TEXT,
            cost_date DATE,
            cost_label TEXT,
            price_number TEXT,
            price_currency TEXT,
            source_file TEXT,
            line INTEGER,
            source_location TEXT
        );
        CREATE TABLE accounts (
            name TEXT PRIMARY KEY,
            open_date DATE,
            currencies TEXT,
            booking TEXT
        );
        CREATE TABLE prices (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            commodity TEXT NOT NULL,
            amount TEXT NOT NULL,
            currency TEXT NOT NULL
        );
        CREATE TABLE balances (
            id INTEGER PRIMARY KEY,
            account TEXT NOT NULL,
            amount TEXT NOT NULL,
            commodity TEXT NOT NULL
        );
        CREATE TABLE balance_assertions (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            account TEXT NOT NULL,
            amount TEXT NOT NULL,
            commodity TEXT NOT NULL,
            tolerance TEXT,
            difference_amount TEXT,
            difference_currency TEXT
        );
        CREATE TABLE commodities (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            commodity TEXT NOT NULL
        );
        CREATE TABLE documents (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            account TEXT NOT NULL,
            path TEXT NOT NULL,
            tags TEXT,
            links TEXT
        );
        CREATE TABLE notes (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            account TEXT NOT NULL,
            comment TEXT,
            tags TEXT,
            links TEXT
        );
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            type TEXT NOT NULL,
            description TEXT
        );
        CREATE TABLE pads (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            account TEXT NOT NULL,
            source_account TEXT NOT NULL,
            source_file TEXT,
            line INTEGER,
            source_location TEXT
        );
        CREATE TABLE closes (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            account TEXT NOT NULL
        );
        CREATE TABLE queries (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            name TEXT NOT NULL,
            query TEXT NOT NULL,
            source_file TEXT,
            line INTEGER,
            source_location TEXT
        );
        CREATE TABLE custom (
            id INTEGER PRIMARY KEY,
            date DATE NOT NULL,
            type TEXT NOT NULL,
            source_file TEXT,
            line INTEGER,
            source_location TEXT
        );
        CREATE TABLE custom_values (
            id INTEGER PRIMARY KEY,
            custom_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            value_type TEXT NOT NULL,
            value TEXT NOT NULL,
            number TEXT,
            currency TEXT
        );
        CREATE TABLE transaction_metadata (
            id INTEGER PRIMARY KEY,
            transaction_id INTEGER NOT NULL,
            key TEXT NOT NULL,
            value TEXT
        );
        CREATE TABLE posting_metadata (
            id INTEGER PRIMARY KEY,
            posting_id INTEGER NOT NULL,
            key TEXT NOT NULL,
            value TEXT
        );
        CREATE TABLE transaction_tags (
            id INTEGER PRIMARY KEY,
            transaction_id INTEGER NOT NULL,
            tag TEXT NOT NULL
        );
        CREATE TABLE transaction_links (
            id INTEGER PRIMARY KEY,
            transaction_id INTEGER NOT NULL,
            link TEXT NOT NULL
        );
        CREATE TABLE diagnostics (
            id INTEGER PRIMARY KEY,
            source_file TEXT,
            line INTEGER,
            source_location TEXT,
            column_number INTEGER,
            end_line INTEGER,
            end_column INTEGER,
            severity TEXT,
            phase TEXT,
            code TEXT,
            message TEXT
        );
        CREATE TABLE source_files (
            path TEXT PRIMARY KEY
        );
        CREATE TABLE directives (
            id INTEGER PRIMARY KEY,
            type TEXT NOT NULL,
            date DATE,
            source_file TEXT,
            line INTEGER,
            source_location TEXT
        );
        CREATE TABLE directive_metadata (
            id INTEGER PRIMARY KEY,
            directive_id INTEGER NOT NULL,
            key TEXT NOT NULL,
            value TEXT
        );
        """;

    private readonly SqliteConnection _connection;
    private readonly SqliteTransaction _transaction;
    private readonly Dictionary<string, SqliteCommand> _commands = new(StringComparer.Ordinal);

    private BeancountProjectionWriter(SqliteConnection connection)
    {
        _connection = connection;
        _transaction = connection.BeginTransaction();
    }

    /// <summary>Creates the schema and loads every table in one transaction on an open, empty database.</summary>
    public static void Load(SqliteConnection connection, BeancountProjectionRows rows, IReadOnlyList<string> sourceFiles)
    {
        using var writer = new BeancountProjectionWriter(connection);
        writer.Execute(Schema);
        var transactionIds = writer.LoadTransactions(rows.Transactions);
        writer.LoadPostings(rows.Postings, transactionIds);
        writer.LoadAccounts(rows.Accounts);
        writer.LoadPrices(rows.Prices);
        writer.LoadBalances(rows.Balances);
        writer.LoadBalanceAssertions(rows.BalanceAssertions);
        writer.LoadCommodities(rows.Commodities);
        writer.LoadDocuments(rows.Documents);
        writer.LoadNotes(rows.Notes);
        writer.LoadEvents(rows.Events);
        writer.LoadPads(rows.Pads);
        writer.LoadCloses(rows.Closes);
        writer.LoadQueries(rows.Queries);
        writer.LoadCustom(rows.Custom);
        writer.LoadDirectives(rows.Directives);
        writer.LoadDiagnostics(rows.Diagnostics);
        foreach (var file in sourceFiles)
        {
            writer.Insert("INSERT OR IGNORE INTO source_files (path) VALUES (@p0)", file);
        }

        writer._transaction.Commit();
    }

    public void Dispose()
    {
        foreach (var command in _commands.Values)
        {
            command.Dispose();
        }

        _transaction.Dispose();
    }

    private void Execute(string sql)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = _transaction;
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    /// <summary>Runs a cached, prepared insert whose parameters are named <c>@p0</c>, <c>@p1</c> and on, in order.</summary>
    private void Insert(string sql, params ReadOnlySpan<object?> values)
    {
        if (!_commands.TryGetValue(sql, out var command))
        {
            command = _connection.CreateCommand();
            command.Transaction = _transaction;
            command.CommandText = sql;
            for (var i = 0; i < values.Length; i++)
            {
                command.Parameters.Add(new SqliteParameter("@p" + i.ToString(CultureInfo.InvariantCulture), null));
            }

            command.Prepare();
            _commands[sql] = command;
        }

        for (var i = 0; i < values.Length; i++)
        {
            command.Parameters[i].Value = values[i] ?? DBNull.Value;
        }

        command.ExecuteNonQuery();
    }

    private HashSet<long> LoadTransactions(List<LedgerRow> rows)
    {
        var transactionIds = new HashSet<long>();
        long metadataId = 0, tagId = 0, linkId = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Integer(row.Get("id")) is not { } transactionId
                || LedgerValues.Text(row.Get("date")) is not { } date
                || !transactionIds.Add(transactionId))
            {
                continue;
            }

            var position = SourcePosition.From(row.Get("filename"), row.Get("lineno"), row.Get("location"));
            Insert(
                "INSERT INTO transactions (id, date, flag, payee, narration, source_file, line, source_location) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7)",
                transactionId,
                date,
                LedgerValues.Text(row.Get("flag")) ?? "*",
                LedgerValues.Text(row.Get("payee")),
                LedgerValues.Text(row.Get("narration")),
                position?.File,
                position?.Line,
                position?.Formatted);

            foreach (var (key, value) in MetadataPairs(row.Get("_entry_meta")))
            {
                Insert("INSERT INTO transaction_metadata (id, transaction_id, key, value) VALUES (@p0, @p1, @p2, @p3)", ++metadataId, transactionId, key, value);
            }

            foreach (var tag in StringList(row.Get("tags")))
            {
                Insert("INSERT INTO transaction_tags (id, transaction_id, tag) VALUES (@p0, @p1, @p2)", ++tagId, transactionId, tag);
            }

            foreach (var link in StringList(row.Get("links")))
            {
                Insert("INSERT INTO transaction_links (id, transaction_id, link) VALUES (@p0, @p1, @p2)", ++linkId, transactionId, link);
            }
        }

        return transactionIds;
    }

    private void LoadPostings(List<LedgerRow> rows, HashSet<long> transactionIds)
    {
        long postingId = 0, metadataId = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Integer(row.Get("transaction_id")) is not { } transactionId
                || LedgerValues.Text(row.Get("date")) is not { } date
                || LedgerValues.Text(row.Get("account")) is not { } account)
            {
                continue;
            }

            if (!transactionIds.Contains(transactionId))
            {
                throw new BeancountException(BeancountStrings.Format("Beancount/MissingTransaction", transactionId));
            }

            postingId++;
            var position = SourcePosition.From(row.Get("filename"), row.Get("lineno"), row.Get("location"));
            var (priceNumber, priceCurrency) = AmountFields(row.Get("price"));
            Insert(
                """
                INSERT INTO postings
                (id, transaction_id, date, account, amount, commodity, flag,
                 cost_number, cost_currency, cost_date, cost_label, price_number, price_currency,
                 source_file, line, source_location)
                VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, @p9, @p10, @p11, @p12, @p13, @p14, @p15)
                """,
                postingId,
                transactionId,
                date,
                account,
                LedgerValues.Text(row.Get("number")),
                LedgerValues.Text(row.Get("currency")),
                LedgerValues.Text(row.Get("posting_flag")),
                LedgerValues.Text(row.Get("cost_number")),
                LedgerValues.Text(row.Get("cost_currency")),
                LedgerValues.Text(row.Get("cost_date")),
                LedgerValues.Text(row.Get("cost_label")),
                priceNumber,
                priceCurrency,
                position?.File,
                position?.Line,
                position?.Formatted);

            foreach (var (key, value) in MetadataPairs(row.Get("_posting_meta")))
            {
                Insert("INSERT INTO posting_metadata (id, posting_id, key, value) VALUES (@p0, @p1, @p2, @p3)", ++metadataId, postingId, key, value);
            }
        }
    }

    private void LoadAccounts(List<LedgerRow> rows)
    {
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("account")) is not { } name)
            {
                continue;
            }

            Insert(
                "INSERT OR REPLACE INTO accounts (name, open_date, currencies, booking) VALUES (@p0, @p1, @p2, @p3)",
                name,
                LedgerValues.Text(row.Get("open")),
                JoinedList(row.Get("currencies")),
                LedgerValues.Text(row.Get("booking")));
        }
    }

    private void LoadPrices(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("currency")) is not { } commodity
                || LedgerValues.Text(row.Get("date")) is not { } date
                || AmountFields(row.Get("amount")) is not ({ } number, { } currency))
            {
                continue;
            }

            Insert("INSERT INTO prices (id, date, commodity, amount, currency) VALUES (@p0, @p1, @p2, @p3, @p4)", ++id, date, commodity, number, currency);
        }
    }

    private void LoadBalances(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("account")) is not { } account || row.Get("balance") is not LedgerRow balance)
            {
                continue;
            }

            foreach (var position in LedgerValues.Rows(balance.Get("positions")))
            {
                if (LedgerValues.Text(position.Get("number")) is { } number && LedgerValues.Text(position.Get("currency")) is { } currency)
                {
                    Insert("INSERT INTO balances (id, account, amount, commodity) VALUES (@p0, @p1, @p2, @p3)", ++id, account, number, currency);
                }
            }
        }
    }

    private void LoadBalanceAssertions(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("account")) is not { } account
                || LedgerValues.Text(row.Get("date")) is not { } date
                || AmountFields(row.Get("amount")) is not ({ } number, { } commodity))
            {
                continue;
            }

            Insert(
                """
                INSERT INTO balance_assertions
                    (id, date, account, amount, commodity, tolerance, difference_amount, difference_currency)
                VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7)
                """,
                ++id,
                date,
                account,
                number,
                commodity,
                LedgerValues.Text(row.Get("tolerance")),
                LedgerValues.Text(row.Get("difference_amount")),
                LedgerValues.Text(row.Get("difference_currency")));
        }
    }

    private void LoadCommodities(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("date")) is { } date
                && (LedgerValues.Text(row.Get("name")) ?? LedgerValues.Text(row.Get("commodity"))) is { } commodity)
            {
                Insert("INSERT INTO commodities (id, date, commodity) VALUES (@p0, @p1, @p2)", ++id, date, commodity);
            }
        }
    }

    private void LoadDocuments(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("date")) is { } date
                && LedgerValues.Text(row.Get("account")) is { } account
                && (LedgerValues.Text(row.Get("filename")) ?? LedgerValues.Text(row.Get("path"))) is { } path)
            {
                Insert(
                    "INSERT INTO documents (id, date, account, path, tags, links) VALUES (@p0, @p1, @p2, @p3, @p4, @p5)",
                    ++id, date, account, path, JoinedList(row.Get("tags")), JoinedList(row.Get("links")));
            }
        }
    }

    private void LoadNotes(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("date")) is { } date && LedgerValues.Text(row.Get("account")) is { } account)
            {
                Insert(
                    "INSERT INTO notes (id, date, account, comment, tags, links) VALUES (@p0, @p1, @p2, @p3, @p4, @p5)",
                    ++id, date, account, LedgerValues.Text(row.Get("comment")), JoinedList(row.Get("tags")), JoinedList(row.Get("links")));
            }
        }
    }

    private void LoadEvents(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("date")) is { } date && LedgerValues.Text(row.Get("type")) is { } type)
            {
                Insert("INSERT INTO events (id, date, type, description) VALUES (@p0, @p1, @p2, @p3)", ++id, date, type, LedgerValues.Text(row.Get("description")));
            }
        }
    }

    private void LoadPads(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("date")) is not { } date
                || LedgerValues.Text(row.Get("account")) is not { } account
                || LedgerValues.Text(row.Get("source_account")) is not { } sourceAccount)
            {
                continue;
            }

            var position = SourcePosition.From(row.Get("filename"), row.Get("lineno"), row.Get("location"));
            Insert(
                "INSERT INTO pads (id, date, account, source_account, source_file, line, source_location) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6)",
                ++id, date, account, sourceAccount, position?.File, position?.Line, position?.Formatted);
        }
    }

    private void LoadCloses(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("account")) is { } account
                && (LedgerValues.Text(row.Get("close")) ?? LedgerValues.Text(row.Get("date"))) is { } date)
            {
                Insert("INSERT INTO closes (id, date, account) VALUES (@p0, @p1, @p2)", ++id, date, account);
            }
        }
    }

    private void LoadQueries(List<LedgerRow> rows)
    {
        for (var index = 0; index < rows.Count; index++)
        {
            var row = rows[index];
            if (LedgerValues.Text(row.Get("date")) is not { } date
                || LedgerValues.Text(row.Get("name")) is not { } name
                || LedgerValues.Text(row.Get("query")) is not { } query)
            {
                continue;
            }

            var position = SourcePosition.From(row.Get("filename"), row.Get("lineno"), row.Get("location"));
            Insert(
                "INSERT INTO queries (id, date, name, query, source_file, line, source_location) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6)",
                (long)(index + 1), date, name, query, position?.File, position?.Line, position?.Formatted);
        }
    }

    private void LoadCustom(List<LedgerRow> rows)
    {
        long valueId = 0;
        for (var index = 0; index < rows.Count; index++)
        {
            var row = rows[index];
            if (LedgerValues.Text(row.Get("date")) is not { } date || LedgerValues.Text(row.Get("type")) is not { } type)
            {
                continue;
            }

            var customId = LedgerValues.Integer(row.Get("id")) ?? index + 1;
            var position = SourcePosition.From(row.Get("filename"), row.Get("lineno"), row.Get("location"));
            Insert(
                "INSERT INTO custom (id, date, type, source_file, line, source_location) VALUES (@p0, @p1, @p2, @p3, @p4, @p5)",
                customId, date, type, position?.File, position?.Line, position?.Formatted);

            if (row.Get("values") is not List<object?> values)
            {
                continue;
            }

            for (var valuePosition = 0; valuePosition < values.Count; valuePosition++)
            {
                if (values[valuePosition] is not LedgerRow value
                    || LedgerValues.Text(value.Get("value_type")) is not { } valueType
                    || LedgerValues.Text(value.Get("value")) is not { } rendered)
                {
                    continue;
                }

                Insert(
                    "INSERT INTO custom_values (id, custom_id, position, value_type, value, number, currency) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6)",
                    ++valueId, customId, (long)valuePosition, valueType, rendered, LedgerValues.Text(value.Get("number")), LedgerValues.Text(value.Get("currency")));
            }
        }
    }

    private void LoadDirectives(List<LedgerRow> rows)
    {
        long metadataId = 0;
        foreach (var row in rows)
        {
            if (LedgerValues.Text(row.Get("type")) is not { } type || LedgerValues.Integer(row.Get("id")) is not { } directiveId)
            {
                continue;
            }

            var position = SourcePosition.From(row.Get("filename"), row.Get("lineno"), row.Get("location"));
            Insert(
                "INSERT INTO directives (id, type, date, source_file, line, source_location) VALUES (@p0, @p1, @p2, @p3, @p4, @p5)",
                directiveId, type, LedgerValues.Text(row.Get("date")), position?.File, position?.Line, position?.Formatted);

            foreach (var (key, value) in MetadataPairs(row.Get("_entry_meta")))
            {
                Insert("INSERT INTO directive_metadata (id, directive_id, key, value) VALUES (@p0, @p1, @p2, @p3)", ++metadataId, directiveId, key, value);
            }
        }
    }

    private void LoadDiagnostics(List<LedgerRow> rows)
    {
        long id = 0;
        foreach (var row in rows)
        {
            var position = SourcePosition.From(row.Get("file"), row.Get("line"), null);
            Insert(
                """
                INSERT INTO diagnostics
                (id, source_file, line, source_location, column_number, end_line, end_column, severity, phase, code, message)
                VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, @p9, @p10)
                """,
                ++id,
                position?.File,
                position?.Line,
                position?.Formatted,
                LedgerValues.Integer(row.Get("column")),
                LedgerValues.Integer(row.Get("end_line")),
                LedgerValues.Integer(row.Get("end_column")),
                LedgerValues.Text(row.Get("severity")),
                LedgerValues.Text(row.Get("phase")),
                LedgerValues.Text(row.Get("code")),
                LedgerValues.Text(row.Get("message")));
        }
    }

    private static (string? Number, string? Currency) AmountFields(object? value) =>
        value is LedgerRow amount ? (LedgerValues.Text(amount.Get("number")), LedgerValues.Text(amount.Get("currency"))) : (null, null);

    private static string? JoinedList(object? value)
    {
        if (value is not List<object?> list)
        {
            return LedgerValues.Text(value);
        }

        var items = list.OfType<string>().ToList();
        return items.Count == 0 ? null : string.Join(' ', items);
    }

    private static List<string> StringList(object? value)
    {
        if (value is List<object?> list)
        {
            return list.OfType<string>().ToList();
        }

        return LedgerValues.Text(value) is { } joined
            ? [.. joined.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).SelectMany(part => part.Split(',', StringSplitOptions.RemoveEmptyEntries))]
            : [];
    }

    /// <summary>Metadata as key and text pairs, sorted by key so the ids are stable from one build to the next.</summary>
    private static List<(string Key, string? Value)> MetadataPairs(object? value)
    {
        if (value is not LedgerRow metadata)
        {
            return [];
        }

        var keys = metadata.Keys.ToList();
        keys.Sort(StringComparer.Ordinal);
        var pairs = new List<(string, string?)>(keys.Count);
        foreach (var key in keys)
        {
            pairs.Add((key, metadata[key] switch
            {
                null => null,
                bool b => b ? "TRUE" : "FALSE",
                var raw => LedgerValues.Text(raw) ?? RledgerOutput.CellText(raw),
            }));
        }

        return pairs;
    }

    private sealed record SourcePosition(string? File, long? Line, string? Formatted)
    {
        public static SourcePosition? From(object? file, object? line, object? formatted)
        {
            var path = LedgerValues.Text(file) is { Length: > 0 } text ? text : null;
            var lineNumber = LedgerValues.Integer(line) is { } number && number > 0 ? number : (long?)null;
            if (path is null && lineNumber is null)
            {
                return null;
            }

            var rendered = LedgerValues.Text(formatted) is { Length: > 0 } given
                ? given
                : path is not null && lineNumber is not null ? string.Create(CultureInfo.InvariantCulture, $"{path}:{lineNumber}") : null;
            return new SourcePosition(path, lineNumber, rendered);
        }
    }
}
