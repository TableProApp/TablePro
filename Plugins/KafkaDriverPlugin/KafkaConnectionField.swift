import Foundation
import TableProPluginKit

/// The field ids the connection form writes into `additionalFields`, and the small amount of
/// interpretation the driver does on the way back out.
///
/// These live in one place because the app has to name two of them too: `bootstrapServers` is
/// a host-list field the tunnel adapter clears, and `brokerRouting` is what the tunnel adapter
/// pins. A second spelling anywhere would be a silent mismatch.
enum KafkaConnectionField {
    static let bootstrapServers = "kafkaBootstrapServers"
    static let securityProtocol = "kafkaSecurityProtocol"
    static let saslMechanism = "kafkaSaslMechanism"
    static let brokerRouting = "kafkaBrokerRouting"
    static let connectTimeout = "kafkaConnectTimeout"

    enum SecurityProtocol: String, CaseIterable {
        case plaintext = "PLAINTEXT"
        case ssl = "SSL"
        case saslPlaintext = "SASL_PLAINTEXT"
        case saslSSL = "SASL_SSL"

        var usesSASL: Bool { self == .saslPlaintext || self == .saslSSL }
        var usesTLS: Bool { self == .ssl || self == .saslSSL }
    }

    static func resolvedProtocol(from fields: [String: String]) -> SecurityProtocol {
        SecurityProtocol(rawValue: fields[securityProtocol] ?? "") ?? .plaintext
    }

    /// SASL is used only when the security protocol asks for it. Reading the mechanism alone
    /// would authenticate on a PLAINTEXT listener, which fails in a way that reads like bad
    /// credentials rather than like a misconfigured protocol.
    static func mechanism(from fields: [String: String]) -> KafkaSASLMechanism? {
        guard resolvedProtocol(from: fields).usesSASL else { return nil }
        let rawMechanism = fields[saslMechanism] ?? KafkaSASLMechanism.plain.rawValue
        return KafkaSASLMechanism(rawValue: rawMechanism) ?? .plain
    }

    /// Kafka names encryption and authentication in one field, and TablePro carries them in
    /// two: the security protocol says whether the listener speaks TLS, and the SSL mode says
    /// how strictly to verify it. The protocol is the authority on *whether*.
    ///
    /// Without this, choosing SASL_SSL while the SSL mode sat at its default of Disabled
    /// opened a plaintext socket and sent the SASL password over it. So a TLS protocol with
    /// no mode chosen verifies fully rather than falling back to no encryption, and a
    /// non-TLS protocol never quietly encrypts because a stale mode was left behind.
    static func effectiveSSL(_ ssl: SSLConfiguration, fields: [String: String]) -> SSLConfiguration {
        var resolved = ssl
        if resolvedProtocol(from: fields).usesTLS {
            if !ssl.isEnabled { resolved.mode = .verifyIdentity }
        } else {
            resolved.mode = .disabled
        }
        return resolved
    }

    static func fields() -> [ConnectionField] {
        [
            ConnectionField(
                id: bootstrapServers,
                label: String(localized: "Additional Bootstrap Servers"),
                placeholder: "broker-2:9092",
                required: false,
                fieldType: .hostList,
                section: .connection
            ),
            ConnectionField(
                id: securityProtocol,
                label: String(localized: "Security Protocol"),
                required: true,
                defaultValue: SecurityProtocol.plaintext.rawValue,
                fieldType: .dropdown(options: [
                    .init(value: SecurityProtocol.plaintext.rawValue, label: "PLAINTEXT"),
                    .init(value: SecurityProtocol.ssl.rawValue, label: "SSL"),
                    .init(value: SecurityProtocol.saslPlaintext.rawValue, label: "SASL_PLAINTEXT"),
                    .init(value: SecurityProtocol.saslSSL.rawValue, label: "SASL_SSL")
                ]),
                section: .connection
            ),
            ConnectionField(
                id: saslMechanism,
                label: String(localized: "SASL Mechanism"),
                required: true,
                defaultValue: KafkaSASLMechanism.plain.rawValue,
                fieldType: .dropdown(options: [
                    .init(value: KafkaSASLMechanism.plain.rawValue, label: "PLAIN"),
                    .init(value: KafkaSASLMechanism.scramSHA256.rawValue, label: "SCRAM-SHA-256"),
                    .init(value: KafkaSASLMechanism.scramSHA512.rawValue, label: "SCRAM-SHA-512")
                ]),
                section: .authentication,
                visibleWhen: FieldVisibilityRule(
                    fieldId: securityProtocol,
                    values: [SecurityProtocol.saslPlaintext.rawValue, SecurityProtocol.saslSSL.rawValue]
                )
            ),
            ConnectionField(
                id: brokerRouting,
                label: String(localized: "Broker Addresses"),
                required: false,
                defaultValue: KafkaBrokerRouting.advertised.rawValue,
                fieldType: .dropdown(options: [
                    .init(
                        value: KafkaBrokerRouting.advertised.rawValue,
                        label: String(localized: "Use the addresses the cluster advertises")
                    ),
                    .init(
                        value: KafkaBrokerRouting.bootstrapOnly.rawValue,
                        label: String(localized: "Only use the bootstrap address")
                    )
                ]),
                section: .advanced
            ),
            ConnectionField(
                id: connectTimeout,
                label: String(localized: "Connect Timeout (seconds)"),
                required: false,
                defaultValue: "10",
                fieldType: .stepper(range: ConnectionField.IntRange(1 ... 120)),
                section: .advanced
            )
        ]
    }
}
