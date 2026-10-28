using System.Buffers;
using System.Diagnostics;
using System.Text.Json;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;
using TablePro.Mcp.Tools;

namespace TablePro.Mcp.Protocol;

internal static class JsonRpcErrorCodes
{
    public const int ParseError = -32700;
    public const int InvalidRequest = -32600;
    public const int MethodNotFound = -32601;
    public const int InvalidParams = -32602;
    public const int InternalError = -32603;
}

public static class McpProtocolVersions
{
    public const string Latest = "2025-11-25";

    /// <summary>Newest first. A client asking for one of these gets it back; any other gets <see cref="Latest"/>.</summary>
    public static IReadOnlyList<string> Supported { get; } = [Latest, "2025-06-18", "2025-03-26"];

    public static bool IsSupported(string? version) => version is not null && Supported.Contains(version, StringComparer.Ordinal);
}

/// <summary>
/// JSON-RPC 2.0 for MCP over Streamable HTTP, stateless: no session id, and each POST carries one message whose
/// answer is plain JSON. Nothing here touches HTTP, so tests can drive it directly.
/// </summary>
internal sealed class McpProtocolHandler(McpTools tools, McpAuditLog audit, McpServerOptions options)
{
    /// <summary>The bytes of the response, or null for a notification or a client's response, which get none.</summary>
    public async Task<byte[]?> HandleAsync(ReadOnlyMemory<byte> body, McpPrincipal principal, CancellationToken cancellationToken)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 64 });
        }
        catch (JsonException)
        {
            return Error(default, JsonRpcErrorCodes.ParseError, "Parse error");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Array)
            {
                // Batching left the protocol in 2025-06-18.
                return Error(default, JsonRpcErrorCodes.InvalidRequest, "Batches are not supported; send one message per request");
            }

            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("jsonrpc", out var version) || version.ValueKind != JsonValueKind.String || !version.ValueEquals("2.0"))
            {
                return Error(default, JsonRpcErrorCodes.InvalidRequest, "Invalid Request");
            }

            var hasId = root.TryGetProperty("id", out var id) && id.ValueKind is JsonValueKind.String or JsonValueKind.Number;
            if (root.TryGetProperty("id", out var rawId) && !hasId && rawId.ValueKind != JsonValueKind.Null)
            {
                return Error(default, JsonRpcErrorCodes.InvalidRequest, "id must be a string or a number");
            }

            if (!root.TryGetProperty("method", out var methodElement) || methodElement.ValueKind != JsonValueKind.String)
            {
                // A response to a request the server never sends, or garbage: either way nothing answers it.
                return hasId && !root.TryGetProperty("result", out _) && !root.TryGetProperty("error", out _)
                    ? Error(id, JsonRpcErrorCodes.InvalidRequest, "method is required")
                    : null;
            }

            var method = methodElement.GetString()!;
            root.TryGetProperty("params", out var parameters);
            if (!hasId)
            {
                // Notifications (initialized, cancelled) need nothing from a stateless server.
                return null;
            }

            return method switch
            {
                "initialize" => Initialize(id, parameters),
                "ping" => Result(id, static w =>
                {
                    w.WriteStartObject("result");
                    w.WriteEndObject();
                }),
                "tools/list" => Result(id, ListTools),
                "tools/call" => await CallToolAsync(id, parameters, principal, cancellationToken),
                _ => Error(id, JsonRpcErrorCodes.MethodNotFound, $"Method not found: {method}"),
            };
        }
    }

    private byte[] Initialize(JsonElement id, JsonElement parameters)
    {
        string? requested = null;
        if (parameters.ValueKind == JsonValueKind.Object && parameters.TryGetProperty("protocolVersion", out var v) && v.ValueKind == JsonValueKind.String)
        {
            requested = v.GetString();
        }

        var negotiated = McpProtocolVersions.IsSupported(requested) ? requested! : McpProtocolVersions.Latest;
        return Result(id, w =>
        {
            w.WriteStartObject("result");
            w.WriteString("protocolVersion", negotiated);
            w.WriteStartObject("capabilities");
            w.WriteStartObject("tools");
            w.WriteBoolean("listChanged", false);
            w.WriteEndObject();
            w.WriteEndObject();
            w.WriteStartObject("serverInfo");
            w.WriteString("name", "tablepro");
            w.WriteString("title", "TablePro");
            w.WriteString("version", options.ServerVersion);
            w.WriteEndObject();
            w.WriteString("instructions", McpToolCatalog.Instructions);
            w.WriteEndObject();
        });
    }

    private static void ListTools(Utf8JsonWriter w)
    {
        w.WriteStartObject("result");
        w.WriteStartArray("tools");
        foreach (var tool in McpToolCatalog.All)
        {
            McpToolCatalog.WriteTool(w, tool);
        }

        w.WriteEndArray();
        w.WriteEndObject();
    }

    private async Task<byte[]> CallToolAsync(JsonElement id, JsonElement parameters, McpPrincipal principal, CancellationToken cancellationToken)
    {
        if (parameters.ValueKind != JsonValueKind.Object
            || !parameters.TryGetProperty("name", out var nameElement) || nameElement.ValueKind != JsonValueKind.String)
        {
            return Error(id, JsonRpcErrorCodes.InvalidParams, "tools/call needs a tool name");
        }

        var name = nameElement.GetString()!;
        if (McpToolCatalog.Find(name) is null)
        {
            return Error(id, JsonRpcErrorCodes.InvalidParams, $"Unknown tool: {name}");
        }

        parameters.TryGetProperty("arguments", out var arguments);
        var record = new McpCallRecord { Principal = principal };
        var started = Stopwatch.GetTimestamp();
        string? text = null;
        McpToolException? failure = null;
        try
        {
            text = await tools.CallAsync(name, arguments, record, cancellationToken);
        }
        catch (McpToolException ex)
        {
            failure = ex;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            failure = new McpToolException(McpToolErrorCode.UserCancelled, "the request was cancelled");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The host and drivers are the app's code; whatever they throw still reaches the client as a tool error
            // and the audit log, rather than as a bare HTTP 500 the client cannot explain.
            failure = new McpToolException(McpToolErrorCode.Internal, ex.Message);
        }

        var isError = failure is not null;
        var content = failure is null ? text ?? string.Empty : $"{failure.WireCode}: {failure.Message}";

        audit.Record(new McpAuditEntry(
            DateTimeOffset.Now,
            name,
            record.ConnectionId,
            record.ConnectionName,
            failure?.Code switch
            {
                null => McpAuditOutcome.Succeeded,
                McpToolErrorCode.Denied => McpAuditOutcome.Denied,
                McpToolErrorCode.UserCancelled => McpAuditOutcome.Cancelled,
                _ => McpAuditOutcome.Failed,
            },
            failure?.WireCode,
            failure?.Message,
            record.Sql,
            Stopwatch.GetElapsedTime(started),
            principal.ClientId,
            principal.Name));

        return Result(id, w =>
        {
            w.WriteStartObject("result");
            w.WriteStartArray("content");
            w.WriteStartObject();
            w.WriteString("type", "text");
            w.WriteString("text", content);
            w.WriteEndObject();
            w.WriteEndArray();
            w.WriteBoolean("isError", isError);
            w.WriteEndObject();
        });
    }

    private static byte[] Result(JsonElement id, Action<Utf8JsonWriter> writeResult) => Envelope(id, writeResult);

    internal static byte[] Error(JsonElement id, int code, string message) => Envelope(id, w =>
    {
        w.WriteStartObject("error");
        w.WriteNumber("code", code);
        w.WriteString("message", message);
        w.WriteEndObject();
    });

    private static byte[] Envelope(JsonElement id, Action<Utf8JsonWriter> writeBody)
    {
        var buffer = new ArrayBufferWriter<byte>(512);
        using (var writer = new Utf8JsonWriter(buffer, McpJson.WriterOptions))
        {
            writer.WriteStartObject();
            writer.WriteString("jsonrpc", "2.0");
            writer.WritePropertyName("id");
            if (id.ValueKind is JsonValueKind.String or JsonValueKind.Number)
            {
                id.WriteTo(writer);
            }
            else
            {
                writer.WriteNullValue();
            }

            writeBody(writer);
            writer.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }
}
