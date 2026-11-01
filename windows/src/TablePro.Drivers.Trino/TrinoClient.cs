using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Drivers.Trino.Localization;

namespace TablePro.Drivers.Trino;

/// <summary>What one statement returned once its pages were read, or up to the row limit.</summary>
internal sealed record TrinoStatementResult(
    string QueryId,
    IReadOnlyList<TrinoColumn>? Columns,
    List<object?[]> Rows,
    bool IsTruncated,
    string? UpdateType,
    long? UpdateCount,
    IReadOnlyList<string> Warnings)
{
    public ResultSet ToResultSet()
    {
        var columns = (Columns ?? []).Select(c => new ResultColumn(c.Name, c.Type, TrinoTypes.ClrType(c.RawType))).ToArray();
        return new ResultSet(columns, Rows, IsTruncated);
    }
}

/// <summary>
/// The client protocol over HTTP: POST the statement, follow <c>nextUri</c> until it is gone, and DELETE the current
/// <c>nextUri</c> to stop a query early. Every page is decoded as it arrives, so a capped read stops fetching.
/// </summary>
internal sealed partial class TrinoClient
{
    private const int MaxTransientRetries = 5;

    private readonly HttpClient _http;
    private readonly TrinoSettings _settings;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;

    public TrinoClient(HttpClient http, TrinoSettings settings, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _http = http;
        _settings = settings;
        _delay = delay ?? Task.Delay;
    }

    public async Task<TrinoStatementResult> ExecuteAsync(string sql, TrinoSessionState state, int rowLimit, CancellationToken cancellationToken)
    {
        var statementUri = new Uri(_settings.BaseUri, "v1/statement");
        string? pending = null;
        try
        {
            var results = await SendAsync(
                () =>
                {
                    var request = new HttpRequestMessage(HttpMethod.Post, statementUri) { Content = new StringContent(sql, Encoding.UTF8, "text/plain") };
                    AddInitialHeaders(request.Headers, state);
                    return request;
                },
                state,
                cancellationToken);

            IReadOnlyList<TrinoColumn>? columns = null;
            Func<JsonElement, object?>[] decoders = [];
            var rows = new List<object?[]>();
            var warnings = new List<string>();
            var truncated = false;
            string? updateType = null;
            long? updateCount = null;
            var queryId = results.Id;

            while (true)
            {
                if (results.Error is { } error)
                {
                    throw new TrinoQueryException(TrinoTypes.Describe(error), error.ErrorName, error.ErrorCode);
                }

                if (columns is null && results.Columns is { } reported)
                {
                    columns = reported;
                    decoders = [.. reported.Select(c => TrinoTypes.Decoder(c.RawType))];
                }

                if (results.Data is { } data && columns is not null)
                {
                    foreach (var raw in data)
                    {
                        if (rows.Count >= rowLimit)
                        {
                            truncated = true;
                            break;
                        }

                        rows.Add(DecodeRow(raw, decoders));
                    }
                }

                updateType = results.UpdateType ?? updateType;
                updateCount = results.UpdateCount ?? updateCount;
                if (results.Warnings is { } reportedWarnings)
                {
                    warnings.AddRange(reportedWarnings.Select(w => w.Message).Where(m => !warnings.Contains(m)));
                }

                pending = results.NextUri;
                if (pending is null || truncated)
                {
                    break;
                }

                var next = FollowUri(pending);
                results = await SendAsync(() => AuthorizedRequest(HttpMethod.Get, next), state, cancellationToken);
            }

            if (truncated && pending is not null)
            {
                // The rest of a capped result is not wanted; releasing the query frees the cluster's resources now.
                await CancelAsync(pending);
            }

            return new TrinoStatementResult(queryId, columns, rows, truncated, updateType, updateCount, warnings);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (pending is not null)
            {
                await CancelAsync(pending);
            }

            throw;
        }
    }

    /// <summary>Tells the coordinator to drop the query. Best effort: the user already has the answer they wanted.</summary>
    internal async Task CancelAsync(string nextUri)
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            using var request = AuthorizedRequest(HttpMethod.Delete, FollowUri(nextUri));
            using var response = await _http.SendAsync(request, timeout.Token);
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or InvalidOperationException or UriFormatException)
        {
            // A query the server already finished or forgot needs no release.
        }
    }

    private static object?[] DecodeRow(JsonElement[] raw, Func<JsonElement, object?>[] decoders)
    {
        var row = new object?[decoders.Length];
        var count = Math.Min(raw.Length, decoders.Length);
        for (var i = 0; i < count; i++)
        {
            row[i] = TrinoTypes.Decode(raw[i], decoders[i]);
        }

        return row;
    }

    private void AddInitialHeaders(HttpRequestHeaders headers, TrinoSessionState state)
    {
        headers.TryAddWithoutValidation(TrinoHeaders.User, _settings.User);
        headers.TryAddWithoutValidation(TrinoHeaders.Source, _settings.Source);
        if (_settings.TimeZone is { } zone)
        {
            headers.TryAddWithoutValidation(TrinoHeaders.TimeZone, zone);
        }

        // Without it, Trino 4xx sends timestamps with the precision the column declares rather than rounded to millis.
        headers.TryAddWithoutValidation(TrinoHeaders.ClientCapabilities, "PATH,PARAMETRIC_DATETIME,SESSION_AUTHORIZATION");
        state.ApplyTo(headers);
        headers.Authorization = _settings.Authorization;
    }

    private HttpRequestMessage AuthorizedRequest(HttpMethod method, Uri uri)
    {
        var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = _settings.Authorization;
        request.Headers.TryAddWithoutValidation(TrinoHeaders.User, _settings.User);
        return request;
    }

    private Uri FollowUri(string uri)
    {
        var next = new Uri(uri, UriKind.Absolute);

        // Following a plain address after an HTTPS start would send the credentials in clear text.
        if (_settings.UsesTls && next.Scheme != Uri.UriSchemeHttps)
        {
            throw new TrinoHttpException(
                0,
                TrinoStrings.Get("Trino/PlainHttpRedirect"));
        }

        return next;
    }

    private async Task<TrinoQueryResults> SendAsync(Func<HttpRequestMessage> createRequest, TrinoSessionState state, CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            using var request = createRequest();
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            var status = (int)response.StatusCode;
            if (response.IsSuccessStatusCode)
            {
                state.Apply(response.Headers);
                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
                try
                {
                    return await JsonSerializer.DeserializeAsync(stream, TrinoJsonContext.Default.TrinoQueryResults, cancellationToken)
                        ?? throw new TrinoHttpException(status, CoreStrings.Format("Driver/EmptyResponse", "Trino"));
                }
                catch (JsonException ex)
                {
                    throw new TrinoHttpException(status, TrinoStrings.Format("Trino/NotClientProtocol", ex.Message));
                }
            }

            // The protocol asks clients to retry these; anything else is final.
            if (status is 429 or 502 or 503 or 504 && attempt <= MaxTransientRetries)
            {
                var retryAfter = response.Headers.RetryAfter?.Delta;
                var wait = retryAfter is { } delta && delta > TimeSpan.Zero
                    ? TimeSpan.FromSeconds(Math.Min(delta.TotalSeconds, 10))
                    : TimeSpan.FromMilliseconds(Math.Min(50 * attempt + 50, 1000));
                await _delay(wait, cancellationToken);
                continue;
            }

            var body = await ReadBodyAsync(response, cancellationToken);
            throw status switch
            {
                401 or 403 => new TrinoHttpException(status, string.IsNullOrEmpty(body) ? TrinoStrings.Get("Trino/CredentialsRefused") : TrinoStrings.Format("Trino/CredentialsRefusedWith", body)),
                _ => new TrinoHttpException(
                    status,
                    string.IsNullOrEmpty(body)
                        ? TrinoStrings.Format("Trino/AnsweredHttp", status, response.ReasonPhrase)
                        : TrinoStrings.Format("Trino/AnsweredHttpWith", status, response.ReasonPhrase, body)),
            };
        }
    }

    private static async Task<string> ReadBodyAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var text = (await response.Content.ReadAsStringAsync(cancellationToken)).Trim();

        // A proxy's HTML error page says nothing useful in a message box.
        if (text.StartsWith('<'))
        {
            text = WebUtility.HtmlDecode(MarkupTag().Replace(text, " ")).Trim();
        }

        return text.Length > 500 ? text[..500] : text;
    }

    [System.Text.RegularExpressions.GeneratedRegex("<[^>]+>")]
    private static partial System.Text.RegularExpressions.Regex MarkupTag();
}
