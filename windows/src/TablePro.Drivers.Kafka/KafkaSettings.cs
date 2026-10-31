using System.Globalization;
using Confluent.Kafka;
using TablePro.Core.Drivers;
using TablePro.Drivers.Kafka.Localization;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Kafka;

/// <summary>
/// Builds librdkafka's client configuration from a profile. Bootstrap servers come from Host and Port, or the
/// <c>bootstrapServers</c> option for a list; a user name turns on SASL; TLS follows the SSL mode. Any option whose
/// key holds a dot (<c>ssl.ca.location</c>, <c>sasl.oauthbearer.config</c>) passes straight to librdkafka.
/// </summary>
internal static class KafkaSettings
{
    private static readonly string[] BootstrapKeys = ["bootstrapServers", "kafkaBootstrapServers"];
    private static readonly string[] ProtocolKeys = ["securityProtocol", "kafkaSecurityProtocol"];
    private static readonly string[] MechanismKeys = ["saslMechanism", "kafkaSaslMechanism"];

    public static ClientConfig Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var config = new ClientConfig
        {
            BootstrapServers = Option(options, BootstrapKeys) ?? Endpoint(request.Host, request.Port),
            ClientId = "TablePro",
            SocketConnectionSetupTimeoutMs = Math.Max(1, profile.ConnectTimeoutSeconds) * 1000,
            SocketTimeoutMs = Math.Max(10, profile.ConnectTimeoutSeconds * 2) * 1000,
        };

        var hasUser = !string.IsNullOrEmpty(profile.Username);
        var protocol = Option(options, ProtocolKeys) is { } named
            ? ParseProtocol(named)
            : (hasUser, profile.SslMode >= CoreSslMode.Required) switch
            {
                (true, true) => SecurityProtocol.SaslSsl,
                (true, false) => SecurityProtocol.SaslPlaintext,
                (false, true) => SecurityProtocol.Ssl,
                _ => SecurityProtocol.Plaintext,
            };
        config.SecurityProtocol = protocol;

        if (protocol is SecurityProtocol.SaslPlaintext or SecurityProtocol.SaslSsl)
        {
            config.SaslMechanism = ParseMechanism(Option(options, MechanismKeys));
            config.SaslUsername = profile.Username;
            config.SaslPassword = request.Password;
        }

        if (protocol is SecurityProtocol.Ssl or SecurityProtocol.SaslSsl)
        {
            switch (profile.SslMode)
            {
                case CoreSslMode.Required:
                    // Required encrypts without checking who answers, as on the other engines.
                    config.EnableSslCertificateVerification = false;
                    break;
                case CoreSslMode.VerifyCa:
                    config.EnableSslCertificateVerification = true;
                    config.SslEndpointIdentificationAlgorithm = SslEndpointIdentificationAlgorithm.None;
                    break;
                default:
                    config.EnableSslCertificateVerification = true;
                    config.SslEndpointIdentificationAlgorithm = SslEndpointIdentificationAlgorithm.Https;
                    break;
            }
        }

        foreach (var (key, value) in options)
        {
            if (key.Contains('.', StringComparison.Ordinal) && !string.IsNullOrWhiteSpace(value))
            {
                config.Set(key, value);
            }
        }

        return config;
    }

    /// <summary>A consumer that reads without joining a group: assigned partitions, a throwaway group id, no commits.</summary>
    public static ConsumerConfig Reader(ClientConfig client) => new(new Dictionary<string, string>(client))
    {
        GroupId = "tablepro-reader-" + Guid.NewGuid().ToString("N"),
        EnableAutoCommit = false,
        EnableAutoOffsetStore = false,
        AutoOffsetReset = AutoOffsetReset.Earliest,
        EnablePartitionEof = true,
        AllowAutoCreateTopics = false,
    };

    public static ProducerConfig Writer(ClientConfig client) => new(new Dictionary<string, string>(client))
    {
        Acks = Acks.All,
        MessageTimeoutMs = 30_000,
    };

    public static AdminClientConfig Admin(ClientConfig client) => new(new Dictionary<string, string>(client));

    private static string Endpoint(string host, int port)
    {
        var hostPart = host.Contains(':', StringComparison.Ordinal) && !host.StartsWith('[') ? $"[{host}]" : host;
        return string.Create(CultureInfo.InvariantCulture, $"{hostPart}:{port}");
    }

    private static SecurityProtocol ParseProtocol(string value) => value.Trim().ToUpperInvariant().Replace('-', '_') switch
    {
        "PLAINTEXT" => SecurityProtocol.Plaintext,
        "SSL" => SecurityProtocol.Ssl,
        "SASL_PLAINTEXT" => SecurityProtocol.SaslPlaintext,
        "SASL_SSL" => SecurityProtocol.SaslSsl,
        _ => throw new ArgumentException(KafkaStrings.Format("Kafka/NotSecurityProtocol", value)),
    };

    private static SaslMechanism ParseMechanism(string? value) => value?.Trim().ToUpperInvariant().Replace('_', '-') switch
    {
        null or "" or "PLAIN" => SaslMechanism.Plain,
        "SCRAM-SHA-256" => SaslMechanism.ScramSha256,
        "SCRAM-SHA-512" => SaslMechanism.ScramSha512,
        "OAUTHBEARER" => SaslMechanism.OAuthBearer,
        "GSSAPI" => SaslMechanism.Gssapi,
        _ => throw new ArgumentException(KafkaStrings.Format("Kafka/NotSaslMechanism", value)),
    };

    private static string? Option(IReadOnlyDictionary<string, string> options, string[] keys)
    {
        foreach (var key in keys)
        {
            if (options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }
}
