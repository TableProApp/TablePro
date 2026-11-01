using System.Buffers;
using System.Diagnostics;
using System.Text.Json;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Tools;

namespace TablePro.Mcp.Auth;

/// <summary>An HTTP answer for the pairing endpoints: a status, a JSON body and, for a refusal that will lift, when.</summary>
internal sealed record McpHttpAnswer(int Status, byte[] Json, TimeSpan? RetryAfter = null);

/// <summary>
/// Pairing over the MCP server's own port. The macOS app starts pairing from a <c>tablepro://</c> link; this app has no
/// URL handler, so a client starts it with a POST instead and then trades the code with the same exchange call, PKCE
/// included, that the macOS app answers at the same path:
/// <list type="number">
/// <item><c>POST /v1/integrations/pair</c> with <c>client_name</c>, <c>code_challenge</c> (S256) and optionally
/// <c>scopes</c> and <c>connection_ids</c>. TablePro asks the user; the answer is a one-time <c>code</c>.</item>
/// <item><c>POST /v1/integrations/exchange</c> with <c>code</c> and <c>code_verifier</c>, answered with the
/// <c>token</c>.</item>
/// </list>
/// The pair call needs no token, since a client has none yet; the user's answer is the gate, and one question at a
/// time with a lockout after repeated refusals keeps a looping program from burying the user in prompts.
/// </summary>
internal sealed class McpPairingService
{
    public const string PairPath = "/v1/integrations/pair";
    public const string ExchangePath = "/v1/integrations/exchange";

    private const int MaxClientNameChars = 100;
    private const int MaxFieldBytes = 1_024;

    private readonly IMcpHost _host;
    private readonly McpClientRegistry _clients;
    private readonly McpAuditLog _audit;
    private readonly McpServerOptions _options;
    private readonly TimeProvider _time;
    private readonly McpPairingCodes _codes;

    // One pairing question on screen at a time; 1 while one is.
    private int _prompting;

    public McpPairingService(IMcpHost host, McpClientRegistry clients, McpAuditLog audit, McpServerOptions options, TimeProvider time)
    {
        _host = host;
        _clients = clients;
        _audit = audit;
        _options = options;
        _time = time;
        _codes = new McpPairingCodes(time);

        // macOS's exchange policy: five misses in five minutes shut the exchange for fifteen.
        Exchanges = new McpFailureLimiter(5, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(15), time);

        // Three refusals in ten minutes mean something keeps asking that the user does not want; stop asking for ten.
        Refusals = new McpFailureLimiter(3, TimeSpan.FromMinutes(10), TimeSpan.FromMinutes(10), time);
    }

    internal McpFailureLimiter Exchanges { get; }

    internal McpFailureLimiter Refusals { get; }

    internal McpPairingCodes Codes => _codes;

    public async Task<McpHttpAnswer> PairAsync(ReadOnlyMemory<byte> body, CancellationToken cancellationToken)
    {
        var started = Stopwatch.GetTimestamp();
        if (Refusals.LockedFor() is { } locked)
        {
            Record("pairing.request", McpAuditOutcome.Denied, "rate_limited", "Pairing is paused after repeated refusals.", null, null, started);
            return Error(429, "rate_limited", "TablePro refused several pairing requests in a row; try again later.", locked);
        }

        if (!TryParsePair(body, out var request, out var problem))
        {
            Record("pairing.request", McpAuditOutcome.Failed, "invalid_request", problem, null, null, started);
            return Error(400, "invalid_request", problem!);
        }

        if (Interlocked.CompareExchange(ref _prompting, 1, 0) != 0)
        {
            return Error(429, "pairing_busy", "Another client is waiting for the user's answer; try again shortly.", TimeSpan.FromSeconds(10));
        }

        McpPairingApproval? approval;
        try
        {
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            wait.CancelAfter(_options.PairingApprovalTimeout);
            try
            {
                approval = await _host.RequestPairingApprovalAsync(request.Request, wait.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                // The user did not answer in time; that is a no, but not one that counts toward the lockout.
                Record("pairing.request", McpAuditOutcome.Cancelled, "timeout", "The user did not answer in time.", null, request.Request.ClientName, started);
                return Error(403, "access_denied", "The user did not answer in time.");
            }
        }
        catch (OperationCanceledException)
        {
            Record("pairing.request", McpAuditOutcome.Cancelled, "client_gone", "The client went away before the user answered.", null, request.Request.ClientName, started);
            throw;
        }
        finally
        {
            Volatile.Write(ref _prompting, 0);
        }

        if (approval is null)
        {
            Refusals.RecordFailure();
            Record("pairing.denied", McpAuditOutcome.Cancelled, "access_denied", "The user declined the pairing.", null, request.Request.ClientName, started);
            return Error(403, "access_denied", "user_denied");
        }

        Refusals.RecordSuccess();
        var issued = await _clients.IssueAsync(request.Request.ClientName, approval.Permission, approval.ConnectionIds, approval.ExpiresAt, CancellationToken.None);
        var pending = new McpPendingCode(issued.Grant.Id, issued.Grant.Name, issued.Token, issued.Grant.Permission, request.Challenge, _time.GetLocalNow() + McpPairingCodes.ExchangeWindow);
        var code = _codes.Insert(pending, out var expired);
        await ForgetUnexchangedAsync(expired);
        if (code is null)
        {
            await _clients.DeleteAsync(issued.Grant.Id, CancellationToken.None);
            return Error(429, "too_many_codes", "Too many pairing codes are waiting for their exchange; try again later.", McpPairingCodes.ExchangeWindow);
        }

        Record("pairing.approved", McpAuditOutcome.Succeeded, null, McpClientRegistry.Describe(issued.Grant), issued.Grant.Id, issued.Grant.Name, started);
        return Json(200, w =>
        {
            w.WriteString("code", code);
            w.WriteNumber("expires_in", (int)McpPairingCodes.ExchangeWindow.TotalSeconds);
            w.WriteString("client_id", issued.Grant.Id);
        });
    }

    public async Task<McpHttpAnswer> ExchangeAsync(ReadOnlyMemory<byte> body)
    {
        var started = Stopwatch.GetTimestamp();
        if (Exchanges.LockedFor() is { } locked)
        {
            Record("pairing.exchange", McpAuditOutcome.Denied, "rate_limited", $"retryAfter={(int)Math.Ceiling(locked.TotalSeconds)}s", null, null, started);
            return Error(429, "rate_limited", "Too many failed exchanges; try again later.", locked);
        }

        if (!TryParseExchange(body, out var code, out var verifier, out var problem))
        {
            Record("pairing.exchange", McpAuditOutcome.Denied, "invalid_request", problem, null, null, started);
            return Error(400, "invalid_request", problem!);
        }

        if (!McpPkce.IsValidVerifier(verifier))
        {
            _codes.Discard(code);
            Exchanges.RecordFailure();
            Record("pairing.exchange", McpAuditOutcome.Denied, "invalid_request", "The pairing verifier is malformed.", null, null, started);
            return Error(400, "invalid_request", "The pairing verifier is malformed.");
        }

        var outcome = _codes.Consume(code, verifier, out var record);
        if (outcome != McpCodeOutcome.Exchanged)
        {
            Exchanges.RecordFailure();
            if (outcome == McpCodeOutcome.Expired && record is not null)
            {
                await ForgetUnexchangedAsync([record]);
            }

            var (status, error, message) = outcome switch
            {
                McpCodeOutcome.Expired => (410, "expired", "Pairing code expired"),
                McpCodeOutcome.Mismatch => (403, "forbidden", "Challenge mismatch"),
                _ => (404, "not_found", "Pairing code not found"),
            };
            Record("pairing.exchange", McpAuditOutcome.Denied, error, message, record?.ClientId, record?.ClientName, started);
            return Error(status, error, message);
        }

        Exchanges.RecordSuccess();
        Record("pairing.exchange", McpAuditOutcome.Succeeded, null, null, record!.ClientId, record.ClientName, started);
        return Json(200, w =>
        {
            w.WriteString("token", record.Token);
            w.WriteString("scope", record.Permission == McpClientPermission.ReadWrite ? "read_write" : "read_only");
            w.WriteString("client_id", record.ClientId);
        });
    }

    /// <summary>
    /// A grant whose code ran out was never collected, so no client holds its token; removing it keeps the list to
    /// clients that exist.
    /// </summary>
    private async Task ForgetUnexchangedAsync(IReadOnlyList<McpPendingCode> expired)
    {
        foreach (var stale in expired)
        {
            if (_clients.Find(stale.ClientId) is { LastUsedAt: null })
            {
                await _clients.DeleteAsync(stale.ClientId, CancellationToken.None);
            }
        }
    }

    private static bool TryParsePair(ReadOnlyMemory<byte> body, out ParsedPair parsed, out string? problem)
    {
        parsed = default;
        if (!TryParseObject(body, out var document, out problem))
        {
            return false;
        }

        using (document)
        {
            var root = document!.RootElement;
            if (!root.TryGetProperty("client_name", out var nameElement) || nameElement.ValueKind != JsonValueKind.String
                || nameElement.GetString()!.Trim() is not { Length: > 0 } name)
            {
                problem = "client_name is required";
                return false;
            }

            if (name.Length > MaxClientNameChars || name.Any(char.IsControl))
            {
                problem = $"client_name must be at most {MaxClientNameChars} printable characters";
                return false;
            }

            if (!root.TryGetProperty("code_challenge", out var challengeElement) || challengeElement.ValueKind != JsonValueKind.String
                || !McpPkce.IsValidChallenge(challengeElement.GetString()))
            {
                problem = "code_challenge must be the 43-character base64url SHA-256 of the verifier";
                return false;
            }

            if (root.TryGetProperty("code_challenge_method", out var method)
                && (method.ValueKind != JsonValueKind.String || !method.ValueEquals("S256")))
            {
                problem = "code_challenge_method must be S256";
                return false;
            }

            string? scopes = null;
            if (root.TryGetProperty("scopes", out var scopesElement))
            {
                if (scopesElement.ValueKind != JsonValueKind.String)
                {
                    problem = "scopes must be a string";
                    return false;
                }

                scopes = scopesElement.GetString();
            }

            // Only an absent field means every connection. Naming it and handing over something unreadable must not
            // widen a request scoped to one connection into one for all of them (the macOS app's #2930).
            List<Guid>? connections = null;
            if (root.TryGetProperty("connection_ids", out var idsElement))
            {
                connections = [];
                IEnumerable<string?> raw = idsElement.ValueKind switch
                {
                    JsonValueKind.Array => idsElement.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString() : null),
                    JsonValueKind.String => idsElement.GetString()!.Split(','),
                    _ => [null],
                };
                foreach (var id in raw)
                {
                    if (!Guid.TryParse(id?.Trim(), out var guid))
                    {
                        problem = $"connection_ids holds something that is not a connection id: {id}";
                        return false;
                    }

                    connections.Add(guid);
                }
            }

            parsed = new ParsedPair(new McpPairingRequest(name, McpScopes.Parse(scopes), connections), challengeElement.GetString()!);
            return true;
        }
    }

    private static bool TryParseExchange(ReadOnlyMemory<byte> body, out string code, out string verifier, out string? problem)
    {
        code = verifier = string.Empty;
        if (!TryParseObject(body, out var document, out problem))
        {
            return false;
        }

        using (document)
        {
            var root = document!.RootElement;
            if (!root.TryGetProperty("code", out var codeElement) || codeElement.ValueKind != JsonValueKind.String
                || !root.TryGetProperty("code_verifier", out var verifierElement) || verifierElement.ValueKind != JsonValueKind.String
                || codeElement.GetString() is not { Length: > 0 } c || verifierElement.GetString() is not { Length: > 0 } v)
            {
                problem = "Missing code or code_verifier";
                return false;
            }

            if (c.Length > MaxFieldBytes || v.Length > MaxFieldBytes)
            {
                problem = "Field exceeds size limit";
                return false;
            }

            code = c;
            verifier = v;
            return true;
        }
    }

    private static bool TryParseObject(ReadOnlyMemory<byte> body, out JsonDocument? document, out string? problem)
    {
        document = null;
        problem = null;
        try
        {
            document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 8 });
        }
        catch (JsonException)
        {
            problem = "Invalid JSON body";
            return false;
        }

        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            document.Dispose();
            document = null;
            problem = "The body must be a JSON object";
            return false;
        }

        return true;
    }

    private void Record(string action, McpAuditOutcome outcome, string? code, string? message, Guid? clientId, string? clientName, long started) =>
        _audit.Record(new McpAuditEntry(_time.GetLocalNow(), action, null, null, outcome, code, message, null, Stopwatch.GetElapsedTime(started), clientId, clientName, McpAuditCategory.Auth));

    private static McpHttpAnswer Error(int status, string error, string message, TimeSpan? retryAfter = null) => Json(status, w =>
    {
        w.WriteString("error", error);
        w.WriteString("error_description", message);
    }, retryAfter);

    private static McpHttpAnswer Json(int status, Action<Utf8JsonWriter> write, TimeSpan? retryAfter = null)
    {
        var buffer = new ArrayBufferWriter<byte>(256);
        using (var writer = new Utf8JsonWriter(buffer, McpJson.WriterOptions))
        {
            writer.WriteStartObject();
            write(writer);
            writer.WriteEndObject();
        }

        return new McpHttpAnswer(status, buffer.WrittenSpan.ToArray(), retryAfter);
    }

    private readonly record struct ParsedPair(McpPairingRequest Request, string Challenge);
}

/// <summary>
/// The <c>scopes</c> a pairing client asks for: one permission level, separated by commas or spaces. Unknown entries
/// are skipped (RFC 6749, 3.3), and when several levels are named the lowest wins, as on macOS.
/// </summary>
public static class McpScopes
{
    public static McpClientPermission Parse(string? raw)
    {
        var entries = (raw ?? string.Empty).ToLowerInvariant().Split([' ', ',', '\t', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries);
        var levels = entries.Select(Level).OfType<McpClientPermission>().ToArray();
        return levels.Length == 0 || levels.Contains(McpClientPermission.ReadOnly) ? McpClientPermission.ReadOnly : McpClientPermission.ReadWrite;
    }

    private static McpClientPermission? Level(string entry) => entry switch
    {
        "readonly" or "read_only" or "read-only" => McpClientPermission.ReadOnly,

        // This app has no administrative tools, so full access is the same as read and write.
        "readwrite" or "read_write" or "read-write" or "fullaccess" or "full_access" or "full-access" or "full" => McpClientPermission.ReadWrite,
        _ => null,
    };
}
