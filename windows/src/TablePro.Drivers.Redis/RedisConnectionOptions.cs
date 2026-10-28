using System.Globalization;
using System.Net.Security;
using StackExchange.Redis;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis;

/// <summary>Turns a connection request into the client library's options, and names databases as the sidebar does.</summary>
internal static class RedisConnectionOptions
{
    public const string ClientName = "TablePro";

    /// <summary>
    /// Form fields win over <see cref="ConnectionProfile.AdditionalOptions"/>, which carry only what the form has no
    /// field for (<c>syncTimeout</c>, <c>protocol</c>, <c>sslHost</c> and the like).
    /// </summary>
    public static ConfigurationOptions Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var extra = profile.AdditionalOptions
            .Where(p => !string.IsNullOrWhiteSpace(p.Key))
            .Select(p => $"{p.Key.Trim()}={p.Value}")
            .ToArray();
        var options = extra.Length == 0 ? new ConfigurationOptions() : ConfigurationOptions.Parse(string.Join(',', extra), ignoreUnknown: true);

        options.EndPoints.Clear();
        options.EndPoints.Add(request.Host, request.Port > 0 ? request.Port : profile.EffectivePort);
        options.Password = string.IsNullOrEmpty(request.Password) ? null : request.Password;
        options.User = string.IsNullOrWhiteSpace(profile.Username) ? null : profile.Username.Trim();
        options.DefaultDatabase = ParseDatabaseIndex(request.Database);
        options.ConnectTimeout = (int)Math.Clamp(profile.ConnectTimeoutSeconds * 1000L, 1000, int.MaxValue);
        options.AbortOnConnectFail = true;

        // The editor runs CONFIG, CLIENT, INFO and FLUSHDB, which the library refuses without admin mode. Safe Mode
        // and the read-only guard decide what may run, not the library.
        options.AllowAdmin = true;
        options.ClientName ??= ClientName;

        var mode = profile.SslMode;
        options.Ssl = UsesTls(mode);
        if (options.Ssl)
        {
            // Through an SSH tunnel the endpoint is 127.0.0.1, while the certificate names the host the user typed.
            options.SslHost ??= profile.Host;
            options.CertificateValidation += (_, _, _, errors) => AcceptsCertificate(mode, errors);
        }

        return options;
    }

    /// <summary>Redis has no in-band TLS upgrade, so Preferred cannot fall back and stays plain like Disabled.</summary>
    public static bool UsesTls(SslMode mode) => mode is SslMode.Required or SslMode.VerifyCa or SslMode.VerifyIdentity;

    public static bool AcceptsCertificate(SslMode mode, SslPolicyErrors errors) => mode switch
    {
        SslMode.Required => true,
        SslMode.VerifyCa => (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None,
        _ => errors == SslPolicyErrors.None,
    };

    /// <summary>The database number from <c>3</c> or <c>db3</c>; empty means database 0.</summary>
    public static int ParseDatabaseIndex(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return 0;
        }

        return TryParseDatabaseIndex(text, out var index)
            ? index
            : throw new ArgumentException($"'{text}' is not a Redis database number. Use a number such as 0 or a name such as db0.");
    }

    public static bool TryParseDatabaseIndex(string? text, out int index)
    {
        index = 0;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var span = text.AsSpan().Trim();
        if (span.StartsWith("db", StringComparison.OrdinalIgnoreCase))
        {
            span = span[2..];
        }

        return int.TryParse(span, NumberStyles.None, CultureInfo.InvariantCulture, out index);
    }

    public static string SchemaName(int index) => string.Create(CultureInfo.InvariantCulture, $"db{index}");
}
