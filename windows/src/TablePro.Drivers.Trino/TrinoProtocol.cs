using System.Text.Json;
using System.Text.Json.Serialization;

namespace TablePro.Drivers.Trino;

/// <summary>One response of the client protocol: the first answer to POST /v1/statement and every page after it.</summary>
internal sealed class TrinoQueryResults
{
    public string Id { get; init; } = string.Empty;

    public string? InfoUri { get; init; }

    public string? NextUri { get; init; }

    public List<TrinoColumn>? Columns { get; init; }

    public List<JsonElement[]>? Data { get; init; }

    public TrinoErrorInfo? Error { get; init; }

    public string? UpdateType { get; init; }

    public long? UpdateCount { get; init; }

    public TrinoStats? Stats { get; init; }

    public List<TrinoWarning>? Warnings { get; init; }
}

internal sealed class TrinoColumn
{
    public string Name { get; init; } = string.Empty;

    public string Type { get; init; } = string.Empty;

    public TrinoTypeSignature? TypeSignature { get; init; }

    /// <summary>The base type without parameters, such as <c>varchar</c> for <c>varchar(20)</c>.</summary>
    public string RawType => TypeSignature?.RawType is { Length: > 0 } raw ? raw : TrinoTypes.BaseType(Type);
}

internal sealed class TrinoTypeSignature
{
    public string RawType { get; init; } = string.Empty;
}

internal sealed class TrinoErrorInfo
{
    public string Message { get; init; } = string.Empty;

    public int ErrorCode { get; init; }

    public string? ErrorName { get; init; }

    public string? ErrorType { get; init; }

    public TrinoErrorLocation? ErrorLocation { get; init; }
}

internal sealed class TrinoErrorLocation
{
    public int LineNumber { get; init; }

    public int ColumnNumber { get; init; }
}

internal sealed class TrinoStats
{
    public string? State { get; init; }
}

internal sealed class TrinoWarning
{
    public string Message { get; init; } = string.Empty;
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, NumberHandling = JsonNumberHandling.AllowReadingFromString)]
[JsonSerializable(typeof(TrinoQueryResults))]
internal sealed partial class TrinoJsonContext : JsonSerializerContext;

/// <summary>The request and response headers of the protocol. Presto spells them with <c>X-Presto-</c>.</summary>
internal static class TrinoHeaders
{
    public const string User = "X-Trino-User";
    public const string Source = "X-Trino-Source";
    public const string Catalog = "X-Trino-Catalog";
    public const string Schema = "X-Trino-Schema";
    public const string TimeZone = "X-Trino-Time-Zone";
    public const string Session = "X-Trino-Session";
    public const string PreparedStatement = "X-Trino-Prepared-Statement";
    public const string TransactionId = "X-Trino-Transaction-Id";
    public const string ClientCapabilities = "X-Trino-Client-Capabilities";

    public const string SetCatalog = "X-Trino-Set-Catalog";
    public const string SetSchema = "X-Trino-Set-Schema";
    public const string SetSession = "X-Trino-Set-Session";
    public const string ClearSession = "X-Trino-Clear-Session";
    public const string AddedPrepare = "X-Trino-Added-Prepare";
    public const string DeallocatedPrepare = "X-Trino-Deallocated-Prepare";
    public const string StartedTransactionId = "X-Trino-Started-Transaction-Id";
    public const string ClearTransactionId = "X-Trino-Clear-Transaction-Id";
}

/// <summary>The server refused or failed the statement.</summary>
public sealed class TrinoQueryException(string message, string? errorName = null, int errorCode = 0) : Exception(message)
{
    public string? ErrorName { get; } = errorName;

    public int ErrorCode { get; } = errorCode;
}

/// <summary>The coordinator answered with an HTTP status the protocol does not expect.</summary>
public sealed class TrinoHttpException(int statusCode, string message) : Exception(message)
{
    public int StatusCode { get; } = statusCode;
}
