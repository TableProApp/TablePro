using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Cassandra;
using TablePro.Drivers.Cassandra.Localization;

namespace TablePro.Drivers.Cassandra;

/// <summary>AWS credentials and the region Amazon Keyspaces signs the login for.</summary>
public sealed record KeyspacesCredentials(string AccessKeyId, string SecretAccessKey, string? SessionToken, string Region)
{
    // The secret never reaches a log or a debugger display through the record's generated ToString.
    public override string ToString() => $"KeyspacesCredentials {{ AccessKeyId = {AccessKeyId}, Region = {Region} }}";
}

/// <summary>
/// The SigV4 SASL exchange Amazon Keyspaces accepts instead of a password, as AWS's own Keyspaces authentication
/// plugins do it: announce SigV4, then sign the server's nonce as the payload of a PUT to <c>/authenticate</c>.
/// </summary>
public static class KeyspacesSigV4
{
    public const int NonceLength = 32;

    private const string Service = "cassandra";
    private const int ExpirySeconds = 900;

    public static ReadOnlySpan<byte> InitialResponse => "SigV4\0\0"u8;

    public static byte[]? Nonce(ReadOnlySpan<byte> challenge)
    {
        var key = "nonce="u8;
        var start = challenge.IndexOf(key);
        if (start < 0)
        {
            return null;
        }

        start += key.Length;
        return start + NonceLength <= challenge.Length ? challenge.Slice(start, NonceLength).ToArray() : null;
    }

    public static string AuthResponse(ReadOnlySpan<byte> nonce, KeyspacesCredentials credentials, DateTimeOffset now)
    {
        var utc = now.UtcDateTime;
        var amzDate = utc.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var dateStamp = utc.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        var scope = $"{dateStamp}/{credentials.Region}/{Service}/aws4_request";

        var canonical = CanonicalRequest(nonce, $"{credentials.AccessKeyId}/{scope}", amzDate);
        var stringToSign = string.Join('\n', "AWS4-HMAC-SHA256", amzDate, scope, Sha256Hex(Encoding.UTF8.GetBytes(canonical)));

        var key = Hmac(Encoding.UTF8.GetBytes("AWS4" + credentials.SecretAccessKey), dateStamp);
        key = Hmac(key, credentials.Region);
        key = Hmac(key, Service);
        key = Hmac(key, "aws4_request");
        var signature = Convert.ToHexStringLower(Hmac(key, stringToSign));

        var response = $"signature={signature},access_key={credentials.AccessKeyId},amzdate={amzDate}";
        return string.IsNullOrEmpty(credentials.SessionToken) ? response : response + ",session_token=" + credentials.SessionToken;
    }

    internal static string CanonicalRequest(ReadOnlySpan<byte> nonce, string credential, string amzDate)
    {
        // Already in the byte order of the parameter names, which SigV4 requires.
        var query = string.Join(
            '&',
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "X-Amz-Credential=" + UriEncode(credential),
            "X-Amz-Date=" + amzDate,
            "X-Amz-Expires=" + ExpirySeconds.ToString(CultureInfo.InvariantCulture));
        return $"PUT\n/authenticate\n{query}\nhost:{Service}\n\nhost\n{Sha256Hex(nonce)}";
    }

    internal static string UriEncode(string value)
    {
        var sb = new StringBuilder(value.Length * 2);
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            var c = (char)b;
            if (char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' or '~')
            {
                sb.Append(c);
            }
            else
            {
                sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }

        return sb.ToString();
    }

    private static string Sha256Hex(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));

    private static byte[] Hmac(byte[] key, string data) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(data));
}

internal sealed class KeyspacesSigV4AuthProvider(KeyspacesCredentials credentials) : IAuthProvider
{
    public IAuthenticator NewAuthenticator(IPEndPoint host) => new Authenticator(credentials);

    private sealed class Authenticator(KeyspacesCredentials credentials) : IAuthenticator
    {
        public byte[] InitialResponse() => KeyspacesSigV4.InitialResponse.ToArray();

        public byte[] EvaluateChallenge(byte[] challenge)
        {
            var nonce = KeyspacesSigV4.Nonce(challenge)
                ?? throw new AuthenticationException(CassandraStrings.Get("Cassandra/SigV4NoNonce"));
            return Encoding.UTF8.GetBytes(KeyspacesSigV4.AuthResponse(nonce, credentials, DateTimeOffset.UtcNow));
        }
    }
}
