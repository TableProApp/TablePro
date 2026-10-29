using System.Text;
using System.Text.RegularExpressions;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.SurrealDb;

/// <summary>
/// What an editor tab keeps between statements over a stateless HTTP endpoint. <c>USE</c> and side-effect-free
/// <c>LET</c> statements are replayed ahead of each later statement, and the statements between <c>BEGIN</c> and
/// <c>COMMIT</c> are held and sent as one request, which is the only way a transaction spans them over HTTP.
/// </summary>
internal sealed partial class SurrealChannelState
{
    private readonly SurrealDbSession _session;
    private readonly List<string> _carried = [];
    private List<string>? _transaction;
    private string? _namespace;
    private string? _database;

    public SurrealChannelState(SurrealDbSession session)
    {
        _session = session;
        _namespace = session.CurrentDatabase;
        _database = session.DefaultSchema;
    }

    public async Task<StatementOutcome> RunAsync(string statement, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var trimmed = statement.Trim().TrimEnd(';').Trim();
        var kind = SurrealQlDialect.Instance.Classify(trimmed);
        var verb = trimmed.Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToUpperInvariant();

        if (kind == StatementKind.Transaction && verb == "BEGIN")
        {
            _transaction = [];
            return new StatementOutcome([], -1, ["Transaction started. The statements up to COMMIT run together when it is sent."]);
        }

        if (_transaction is not null)
        {
            if (verb is "COMMIT" or "CANCEL")
            {
                var held = _transaction;
                _transaction = null;
                return verb == "CANCEL"
                    ? new StatementOutcome([], -1, [$"Transaction cancelled; {held.Count} statement(s) were not sent."])
                    : await CommitAsync(held, options, cancellationToken);
            }

            _transaction.Add(trimmed);
            return new StatementOutcome([], -1, ["Held for the transaction; it runs at COMMIT."]);
        }

        if (verb == "USE")
        {
            ApplyUse(trimmed);
            return new StatementOutcome([], -1, [$"Using namespace {_namespace ?? "(none)"}, database {_database ?? "(none)"}."]);
        }

        using var response = await _session.QueryAsync(Script([trimmed]), _database, cancellationToken, throwOnError: false, namespaceOverride: _namespace);
        var results = response.Results.Skip(_carried.Count).ToArray();
        var errors = results.Where(r => !r.Ok).Select(r => r.Error ?? string.Empty).ToArray();
        if (errors.Length > 0)
        {
            throw new ServerRequestException(SurrealDbSession.RootCause(errors));
        }

        if (verb == "LET")
        {
            if (!HasWrite(trimmed))
            {
                _carried.Add(trimmed);
                return new StatementOutcome([], -1, ["The variable is kept for the statements that follow in this tab."]);
            }

            return new StatementOutcome([], -1, ["The variable's value writes data, so it is not replayed for later statements."]);
        }

        if (kind is StatementKind.Ddl or StatementKind.Write)
        {
            _session.ForgetKinds();
        }

        return Render(results, kind, options.RowLimit);
    }

    private async Task<StatementOutcome> CommitAsync(List<string> held, ExecuteOptions options, CancellationToken cancellationToken)
    {
        if (held.Count == 0)
        {
            return StatementOutcome.Empty;
        }

        var body = new StringBuilder("BEGIN TRANSACTION;\n");
        foreach (var statement in held)
        {
            body.Append(statement).Append(";\n");
        }

        body.Append("COMMIT TRANSACTION;");
        using var response = await _session.QueryAsync(Script([body.ToString()]), _database, cancellationToken, throwOnError: false, namespaceOverride: _namespace);
        var results = response.Results.Skip(_carried.Count).ToArray();
        var errors = results.Where(r => !r.Ok).Select(r => r.Error ?? string.Empty).ToArray();
        if (errors.Length > 0)
        {
            throw new ServerRequestException("The transaction was cancelled. " + SurrealDbSession.RootCause(errors));
        }

        _session.ForgetKinds();
        var outcome = Render(results, StatementKind.Write, options.RowLimit);
        return outcome with { Messages = [$"Transaction committed: {held.Count} statement(s)."] };
    }

    private string Script(IEnumerable<string> statements)
    {
        var sb = new StringBuilder();
        foreach (var carried in _carried)
        {
            sb.Append(carried).Append(";\n");
        }

        foreach (var statement in statements)
        {
            sb.Append(statement);
            if (!statement.TrimEnd().EndsWith(';'))
            {
                sb.Append(';');
            }

            sb.Append('\n');
        }

        return sb.ToString();
    }

    /// <summary>Reads <c>USE NS a DB b</c>; either part may be left out to keep the current one.</summary>
    private void ApplyUse(string statement)
    {
        var match = UseStatement().Match(statement);
        if (match.Groups["ns"].Success)
        {
            _namespace = Unquote(match.Groups["ns"].Value);
        }

        if (match.Groups["db"].Success)
        {
            _database = Unquote(match.Groups["db"].Value);
        }

        static string Unquote(string name) => name.Length >= 2 && name[0] is '`' or '⟨' ? name[1..^1] : name;
    }

    /// <summary>A LET whose value creates or changes records would repeat that change each time it is replayed.</summary>
    internal static bool HasWrite(string statement) => WriteVerb().IsMatch(StringLiterals().Replace(statement, string.Empty));

    private static StatementOutcome Render(IReadOnlyList<SurrealResult> results, StatementKind kind, int rowLimit)
    {
        var sets = new List<ResultSet>();
        var affected = -1;
        foreach (var result in results)
        {
            if (Table(result, rowLimit) is { } set)
            {
                sets.Add(set);
                if (kind == StatementKind.Write && result.Data is List<object?> written)
                {
                    affected = Math.Max(affected, 0) + written.Count;
                }
            }
        }

        return new StatementOutcome(sets, affected);
    }

    /// <summary>
    /// Records become rows with their top-level fields as columns; an INFO answer or other object becomes path and
    /// value; a plain value is one cell. NONE and NULL produce no result. Columns whose values all are datetimes or
    /// decimals are typed as such, which the RPC's answers make possible.
    /// </summary>
    internal static ResultSet? Table(SurrealResult result, int rowLimit)
    {
        switch (result.Data)
        {
            case List<object?> items:
            {
                var table = new DocumentTable();
                if (items.Any(r => r is SurrealObject record && record.TryGetValue("id", out _)))
                {
                    table.Declare("id", "record", typeof(string));
                }

                var truncated = false;
                var records = new List<SurrealObject>(Math.Min(items.Count, rowLimit));
                foreach (var row in items)
                {
                    if (table.RowCount >= rowLimit)
                    {
                        truncated = true;
                        break;
                    }

                    table.NewRow();
                    Fill(table, row);
                    if (row is SurrealObject record)
                    {
                        records.Add(record);
                    }
                }

                SurrealValues.DeclareTypedColumns(table, records);
                return table.Build(truncated);
            }

            case SurrealObject record when record.TryGetValue("id", out _):
            {
                var table = new DocumentTable();
                table.Declare("id", "record", typeof(string));
                table.NewRow();
                Fill(table, record);
                SurrealValues.DeclareTypedColumns(table, [record]);
                return table.Build();
            }

            case SurrealObject:
                return JsonTables.PathValue(result.Value, rowLimit);

            case null:
                return null;

            case var value:
            {
                var table = new DocumentTable();
                table.NewRow();
                table.Set("result", SurrealValues.ToCell(value));
                var single = new SurrealObject(1);
                single.Add("result", value);
                SurrealValues.DeclareTypedColumns(table, [single]);
                return table.Build();
            }
        }
    }

    private static void Fill(DocumentTable table, object? row)
    {
        if (row is not SurrealObject record)
        {
            table.Set("value", SurrealValues.ToCell(row));
            return;
        }

        foreach (var (name, value) in record.Fields)
        {
            table.Set(name, SurrealValues.ToCell(value));
        }
    }

    [GeneratedRegex(@"^USE(?:\s+(?:NS|NAMESPACE)\s+(?<ns>`[^`]*`|⟨[^⟩]*⟩|[^\s;]+))?(?:\s+(?:DB|DATABASE)\s+(?<db>`[^`]*`|⟨[^⟩]*⟩|[^\s;]+))?", RegexOptions.IgnoreCase)]
    private static partial Regex UseStatement();

    [GeneratedRegex(@"\b(CREATE|UPDATE|UPSERT|DELETE|INSERT|RELATE|DEFINE|REMOVE|ALTER|KILL)\b", RegexOptions.IgnoreCase)]
    private static partial Regex WriteVerb();

    [GeneratedRegex("""'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`""")]
    private static partial Regex StringLiterals();
}
