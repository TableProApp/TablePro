using System.Text.Json;
using TablePro.Core.Results;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.Elasticsearch;

/// <summary>The reason a failed request gives, as <c>type: reason</c>.</summary>
internal static class EsErrors
{
    public static string Reason(HttpReply reply)
    {
        string? reason = null;
        using (var json = reply.TryParseJson())
        {
            if (json is not null && json.RootElement.ValueKind == JsonValueKind.Object)
            {
                var root = json.RootElement;
                if (root.TryGetProperty("error", out var error))
                {
                    reason = error.ValueKind == JsonValueKind.Object ? Describe(error) : error.ToString();
                }
                else if (root.TryGetProperty("message", out var message))
                {
                    reason = message.ToString();
                }
            }
        }

        reason ??= reply.Body.Length > 0 ? reply.Text.Trim() : $"HTTP {reply.StatusCode}";
        return reply.StatusCode is 401 or 403 ? "Authentication failed: " + reason : reason;
    }

    /// <summary>The error's type and reason, with the root cause when it says something the reason does not.</summary>
    public static string Describe(JsonElement error)
    {
        if (error.ValueKind != JsonValueKind.Object)
        {
            return error.ToString();
        }

        var type = error.TryGetProperty("type", out var t) ? t.GetString() : null;
        var reason = error.TryGetProperty("reason", out var r) ? r.GetString() : null;
        var text = string.Join(": ", new[] { type, reason }.Where(s => !string.IsNullOrEmpty(s)));
        if (error.TryGetProperty("caused_by", out var cause) && cause.TryGetProperty("reason", out var causeReason)
            && causeReason.GetString() is { Length: > 0 } detail && !text.Contains(detail, StringComparison.Ordinal))
        {
            text += " (" + detail + ")";
        }

        return text.Length == 0 ? error.GetRawText() : text;
    }
}

/// <summary>Shapes a console response for the grid.</summary>
internal static class EsResponses
{
    public static StatementOutcome Render(HttpReply reply, int rowLimit)
    {
        if (reply.Body.Length == 0)
        {
            return new StatementOutcome([JsonTables.Raw(reply.StatusCode.ToString(System.Globalization.CultureInfo.InvariantCulture), "status")]);
        }

        using var json = reply.TryParseJson();
        if (json is null)
        {
            // _cat without format=json, and other text answers.
            return new StatementOutcome([JsonTables.Raw(reply.Text, "response")]);
        }

        var root = json.RootElement;
        var affected = Affected(root);
        if (root.ValueKind == JsonValueKind.Object && ElasticsearchSession.Hits(root).ValueKind == JsonValueKind.Array
            && !root.TryGetProperty("aggregations", out _) && !root.TryGetProperty("suggest", out _))
        {
            return StatementOutcome.Of(HitsTable(root, rowLimit), affected);
        }

        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("columns", out var columns) && root.TryGetProperty("rows", out var rows)
            && columns.ValueKind == JsonValueKind.Array && rows.ValueKind == JsonValueKind.Array)
        {
            return StatementOutcome.Of(SqlTable(columns, rows, rowLimit), affected);
        }

        return StatementOutcome.Of(JsonTables.Auto(root, rowLimit), affected);
    }

    /// <summary>Hits as rows: the metadata columns, then every source field under its dotted path.</summary>
    public static ResultSet HitsTable(JsonElement root, int rowLimit)
    {
        var table = new DocumentTable();
        table.Declare(EsMapping.IdColumn, "keyword", typeof(string));
        table.Declare(EsMapping.IndexColumn, "keyword", typeof(string));
        table.Declare(EsMapping.ScoreColumn, "float", typeof(double));
        var hits = ElasticsearchSession.Hits(root);
        var truncated = false;
        foreach (var hit in hits.EnumerateArray())
        {
            if (table.RowCount >= rowLimit)
            {
                truncated = true;
                break;
            }

            table.NewRow();
            foreach (var meta in new[] { EsMapping.IdColumn, EsMapping.IndexColumn, EsMapping.ScoreColumn })
            {
                if (hit.TryGetProperty(meta, out var value))
                {
                    table.Set(meta, value);
                }
            }

            if (hit.TryGetProperty("_source", out var source))
            {
                table.SetFlattened(source);
            }
        }

        return table.Build(truncated);
    }

    /// <summary>The <c>_sql</c> endpoint's columns and rows.</summary>
    private static ResultSet SqlTable(JsonElement columns, JsonElement rows, int rowLimit)
    {
        var names = columns.EnumerateArray().Select(c => (Name: c.GetProperty("name").GetString() ?? string.Empty, Type: c.TryGetProperty("type", out var t) ? t.GetString() ?? "keyword" : "keyword")).ToArray();
        var table = new DocumentTable();
        foreach (var (name, type) in names)
        {
            table.Declare(name, type, new EsField(name, type, false).ClrType);
        }

        var truncated = false;
        foreach (var row in rows.EnumerateArray())
        {
            if (table.RowCount >= rowLimit)
            {
                truncated = true;
                break;
            }

            table.NewRow();
            var i = 0;
            foreach (var value in row.EnumerateArray())
            {
                if (i < names.Length)
                {
                    table.Set(names[i].Name, value);
                }

                i++;
            }
        }

        return table.Build(truncated);
    }

    /// <summary>How many documents a write touched, from the counters each write API reports.</summary>
    private static int Affected(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return -1;
        }

        if (root.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
        {
            return items.GetArrayLength();
        }

        foreach (var counter in new[] { "deleted", "updated", "created" })
        {
            if (root.TryGetProperty(counter, out var value) && value.ValueKind == JsonValueKind.Number)
            {
                return value.GetInt32();
            }
        }

        return root.TryGetProperty("result", out var result) && result.ValueKind == JsonValueKind.String && result.GetString() is "created" or "updated" or "deleted" ? 1 : -1;
    }
}
