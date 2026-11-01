using System.Net;
using System.Net.Http.Headers;

namespace TablePro.Drivers.Trino;

/// <summary>
/// What the server asks the client to remember between statements: <c>USE</c>, <c>SET SESSION</c>, prepared
/// statements and an open transaction. The protocol is stateless, so each editor tab keeps its own copy.
/// </summary>
internal sealed class TrinoSessionState
{
    private readonly Lock _lock = new();
    private readonly Dictionary<string, string> _properties = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _prepared = new(StringComparer.Ordinal);

    public TrinoSessionState(string? catalog, string? schema)
    {
        Catalog = catalog;
        Schema = schema;
    }

    public string? Catalog { get; private set; }

    public string? Schema { get; private set; }

    public string? TransactionId { get; private set; }

    public TrinoSessionState Clone()
    {
        lock (_lock)
        {
            var copy = new TrinoSessionState(Catalog, Schema) { TransactionId = TransactionId };
            foreach (var (key, value) in _properties)
            {
                copy._properties[key] = value;
            }

            foreach (var (key, value) in _prepared)
            {
                copy._prepared[key] = value;
            }

            return copy;
        }
    }

    public void ApplyTo(HttpRequestHeaders headers)
    {
        lock (_lock)
        {
            if (!string.IsNullOrEmpty(Catalog))
            {
                headers.TryAddWithoutValidation(TrinoHeaders.Catalog, Catalog);
            }

            if (!string.IsNullOrEmpty(Schema))
            {
                headers.TryAddWithoutValidation(TrinoHeaders.Schema, Schema);
            }

            if (_properties.Count > 0)
            {
                headers.TryAddWithoutValidation(TrinoHeaders.Session, Join(_properties));
            }

            if (_prepared.Count > 0)
            {
                headers.TryAddWithoutValidation(TrinoHeaders.PreparedStatement, Join(_prepared));
            }

            headers.TryAddWithoutValidation(TrinoHeaders.TransactionId, TransactionId ?? "NONE");
        }
    }

    public void Apply(HttpResponseHeaders headers)
    {
        lock (_lock)
        {
            if (First(headers, TrinoHeaders.SetCatalog) is { } catalog)
            {
                Catalog = catalog;
            }

            if (First(headers, TrinoHeaders.SetSchema) is { } schema)
            {
                Schema = schema;
            }

            foreach (var entry in All(headers, TrinoHeaders.SetSession))
            {
                if (Pair(entry) is var (key, value))
                {
                    _properties[key] = value;
                }
            }

            foreach (var key in All(headers, TrinoHeaders.ClearSession))
            {
                _properties.Remove(key.Trim());
            }

            foreach (var entry in All(headers, TrinoHeaders.AddedPrepare))
            {
                if (Pair(entry) is var (key, value))
                {
                    _prepared[key] = value;
                }
            }

            foreach (var key in All(headers, TrinoHeaders.DeallocatedPrepare))
            {
                _prepared.Remove(WebUtility.UrlDecode(key.Trim()));
            }

            if (First(headers, TrinoHeaders.StartedTransactionId) is { } transaction)
            {
                TransactionId = transaction;
            }

            if (headers.Contains(TrinoHeaders.ClearTransactionId))
            {
                TransactionId = null;
            }
        }
    }

    private static string Join(Dictionary<string, string> values) =>
        string.Join(",", values.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => string.Concat(p.Key, "=", Uri.EscapeDataString(p.Value))));

    private static string? First(HttpResponseHeaders headers, string name) =>
        headers.TryGetValues(name, out var values) ? values.FirstOrDefault() : null;

    // A header may repeat, and one value may also carry a comma-separated list.
    private static IEnumerable<string> All(HttpResponseHeaders headers, string name) =>
        headers.TryGetValues(name, out var values)
            ? values.SelectMany(v => v.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            : [];

    private static (string Key, string Value)? Pair(string entry)
    {
        var separator = entry.IndexOf('=', StringComparison.Ordinal);
        if (separator <= 0)
        {
            return null;
        }

        return (WebUtility.UrlDecode(entry[..separator].Trim()), WebUtility.UrlDecode(entry[(separator + 1)..]));
    }
}
