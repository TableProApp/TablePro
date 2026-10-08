import Foundation
import TableProPluginKit

struct KafkaConnectTimeout: Equatable, Sendable {
    static let defaultMilliseconds = 30_000
    static let maximumMilliseconds = 3_600_000

    let milliseconds: Int
    let reconnectMilliseconds: Int

    init(additionalFields: [String: String]) {
        let fullMilliseconds: Int
        if let raw = additionalFields["connectTimeoutSeconds"] {
            fullMilliseconds = Self.parseSeconds(raw) ?? Self.defaultMilliseconds
        } else if let raw = additionalFields[KafkaConnectionField.connectTimeout] {
            fullMilliseconds = Self.parseSeconds(raw) ?? Self.defaultMilliseconds
        } else {
            fullMilliseconds = Self.defaultMilliseconds
        }

        if let raw = additionalFields["connectTimeoutMilliseconds"] {
            milliseconds = Self.parseMilliseconds(raw) ?? Self.defaultMilliseconds
        } else {
            milliseconds = fullMilliseconds
        }
        reconnectMilliseconds = fullMilliseconds
    }

    init(milliseconds: Int) {
        let clamped = min(max(milliseconds, 1), Self.maximumMilliseconds)
        self.milliseconds = clamped
        reconnectMilliseconds = clamped
    }

    private static func parseMilliseconds(_ raw: String) -> Int? {
        guard let value = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return clamp(value)
    }

    private static func parseSeconds(_ raw: String) -> Int? {
        guard let seconds = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000)
        let milliseconds = multiplied.overflow ? (seconds > 0 ? Int64.max : Int64.min) : multiplied.partialValue
        return clamp(milliseconds)
    }

    private static func clamp(_ milliseconds: Int64) -> Int {
        Int(min(max(milliseconds, 1), Int64(maximumMilliseconds)))
    }
}

struct KafkaConnectDeadline: Sendable {
    private let expiresAt: TimeInterval

    init(timeout: KafkaConnectTimeout, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.init(milliseconds: timeout.milliseconds, now: now)
    }

    init(milliseconds: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expiresAt = now + TimeInterval(milliseconds) / 1_000
    }

    func remainingMilliseconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        let remaining = Int(((expiresAt - now) * 1_000).rounded(.up))
        return remaining > 0 ? remaining : nil
    }

    /// An equal share of what is left for each of `attempts`, so one endpoint that never answers
    /// cannot spend the time the others need.
    func remainingMilliseconds(
        sharedBy attempts: Int,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Int? {
        guard let remaining = remainingMilliseconds(now: now) else { return nil }
        return max(1, remaining / max(attempts, 1))
    }
}

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

    /// The form's list, else Host and Port: a tunnel clears the list and points Host and Port at
    /// its local forward. A list saved before it replaced Host and Port named only the extra
    /// brokers, so a Host missing from the list is still dialed, after the list.
    static func bootstrapEndpoints(
        host: String,
        port: Int,
        fields: [String: String],
        defaultPort: Int
    ) -> [KafkaEndpoint] {
        let listed = (fields[bootstrapServers] ?? "")
            .split(separator: ",")
            .compactMap { KafkaEndpoint.parse(String($0), defaultPort: defaultPort) }
        let primary = KafkaEndpoint(host: host.isEmpty ? "127.0.0.1" : host, port: port > 0 ? port : defaultPort)
        if listed.isEmpty { return [primary] }
        return host.isEmpty || listed.contains(primary) ? listed : listed + [primary]
    }

    static func fields() -> [ConnectionField] {
        [
            ConnectionField(
                id: bootstrapServers,
                label: String(localized: "Bootstrap Servers"),
                placeholder: "localhost:9092",
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
            )
        ]
    }
}
