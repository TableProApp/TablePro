import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class LegacyKafkaMetadataPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Legacy Kafka metadata"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Test fixture"
    static let capabilities: [PluginCapability] = [.databaseDriver]
    static let databaseTypeId = "Kafka"
    static let databaseDisplayName = "Kafka"
    static let iconName = "kafka-icon"
    static let defaultPort = 9_092
    static let additionalConnectionFields = [
        ConnectionField(
            id: "kafkaConnectTimeout",
            label: "Connect Timeout (seconds)",
            defaultValue: "10",
            fieldType: .stepper(range: ConnectionField.IntRange(1 ... 120)),
            section: .advanced
        )
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

/// Kafka names encryption and authentication in one setting; TablePro carries them in two.
/// These pin the resolution, because getting it wrong sends a password in the clear.
struct KafkaConnectionFieldTests {
    private func fields(_ securityProtocol: String, mechanism: String? = nil) -> [String: String] {
        var result = ["kafkaSecurityProtocol": securityProtocol]
        if let mechanism { result["kafkaSaslMechanism"] = mechanism }
        return result
    }

    // MARK: - SASL is gated on the protocol

    @Test("PLAINTEXT and SSL never authenticate, whatever mechanism is left in the form")
    func saslIsGatedOnTheProtocol() {
        #expect(KafkaConnectionField.mechanism(from: fields("PLAINTEXT", mechanism: "PLAIN")) == nil)
        #expect(KafkaConnectionField.mechanism(from: fields("SSL", mechanism: "SCRAM-SHA-512")) == nil)
    }

    @Test("The SASL protocols use the chosen mechanism, defaulting to PLAIN")
    func saslMechanismSelection() {
        #expect(KafkaConnectionField.mechanism(from: fields("SASL_SSL", mechanism: "SCRAM-SHA-256")) == .scramSHA256)
        #expect(KafkaConnectionField.mechanism(from: fields("SASL_PLAINTEXT", mechanism: "SCRAM-SHA-512")) == .scramSHA512)
        #expect(KafkaConnectionField.mechanism(from: fields("SASL_SSL")) == .plain)
    }

    @Test("An unrecognised protocol falls back to PLAINTEXT rather than to a SASL one")
    func unknownProtocolDoesNotAuthenticate() {
        #expect(KafkaConnectionField.mechanism(from: ["kafkaSecurityProtocol": "SASL_GSSAPI"]) == nil)
        #expect(KafkaConnectionField.mechanism(from: [:]) == nil)
    }

    // MARK: - TLS follows the protocol

    /// The bug this exists to stop: SSLConfiguration defaults to `.disabled`, so picking
    /// SASL_SSL and leaving the SSL mode alone opened a plaintext socket and sent the SASL
    /// password over it.
    @Test("A TLS protocol with no SSL mode chosen verifies fully instead of disabling TLS")
    func tlsProtocolUpgradesADisabledMode() {
        let resolved = KafkaConnectionField.effectiveSSL(SSLConfiguration(), fields: fields("SASL_SSL"))
        #expect(resolved.isEnabled)
        #expect(resolved.mode == .verifyIdentity)
        #expect(resolved.verifiesCertificate)

        let ssl = KafkaConnectionField.effectiveSSL(SSLConfiguration(), fields: fields("SSL"))
        #expect(ssl.mode == .verifyIdentity)
    }

    @Test("An explicit SSL mode is honoured under a TLS protocol")
    func explicitModeIsKept() {
        for mode in [SSLMode.required, .verifyCa, .verifyIdentity] {
            let resolved = KafkaConnectionField.effectiveSSL(
                SSLConfiguration(mode: mode),
                fields: fields("SASL_SSL")
            )
            #expect(resolved.mode == mode)
        }
    }

    /// The other direction: a mode left behind from an earlier edit must not quietly encrypt
    /// a connection whose protocol says plaintext, which would fail against a plaintext
    /// listener in a way that reads like a broker fault.
    @Test("A non-TLS protocol disables TLS even when a mode was left behind")
    func nonTLSProtocolDisablesTLS() {
        for protocolName in ["PLAINTEXT", "SASL_PLAINTEXT"] {
            let resolved = KafkaConnectionField.effectiveSSL(
                SSLConfiguration(mode: .verifyIdentity),
                fields: fields(protocolName)
            )
            #expect(resolved.isEnabled == false)
            #expect(resolved.mode == .disabled)
        }
    }

    @Test("Certificate paths survive the resolution")
    func certificatePathsSurvive() {
        let resolved = KafkaConnectionField.effectiveSSL(
            SSLConfiguration(
                mode: .verifyCa,
                caCertificatePath: "/tmp/ca.pem",
                clientCertificatePath: "/tmp/client.pem",
                clientKeyPath: "/tmp/client.key"
            ),
            fields: fields("SASL_SSL")
        )
        #expect(resolved.caCertificatePath == "/tmp/ca.pem")
        #expect(resolved.clientCertificatePath == "/tmp/client.pem")
        #expect(resolved.clientKeyPath == "/tmp/client.key")
    }

    // MARK: - Field declarations

    @Test("The common connect timeout wins over the saved Kafka field")
    func commonConnectTimeoutWins() {
        let timeout = KafkaConnectTimeout(additionalFields: [
            "connectTimeoutMilliseconds": "4250",
            "connectTimeoutSeconds": "8",
            "kafkaConnectTimeout": "11"
        ])

        #expect(timeout.milliseconds == 4_250)
        #expect(timeout.reconnectMilliseconds == 8_000)
    }

    @Test("Saved Kafka timeouts migrate through the compatibility fallback")
    func savedConnectTimeoutFallback() {
        #expect(KafkaConnectTimeout(additionalFields: ["kafkaConnectTimeout": "12"]).milliseconds == 12_000)
        #expect(KafkaConnectTimeout(additionalFields: [:]).milliseconds == 30_000)
        #expect(
            KafkaConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int64.min)]).milliseconds == 1
        )
    }

    @Test("Bootstrap attempts consume one monotonic deadline")
    func bootstrapDeadlineShrinks() {
        let deadline = KafkaConnectDeadline(timeout: KafkaConnectTimeout(milliseconds: 4_250), now: 100)

        #expect(deadline.remainingMilliseconds(now: 101.25) == 3_000)
        #expect(deadline.remainingMilliseconds(now: 104.25) == nil)
    }

    @Test("The plugin no longer declares its old timeout control")
    func oldTimeoutControlIsRemoved() {
        #expect(!KafkaConnectionField.fields().contains { $0.id == KafkaConnectionField.connectTimeout })
    }

    @Test("An installed older Kafka bundle cannot restore the retired timeout control")
    func oldPluginMetadataIsNormalized() {
        let snapshot = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: LegacyKafkaMetadataPlugin.self)

        #expect(snapshot.connection.additionalConnectionFields.isEmpty)
    }

    /// The plugin's list and the app's curated copy cannot share code, because the picker has
    /// to show these before the bundle that owns them is downloaded. Nothing but this keeps
    /// the two in step.
    @Test("The plugin's fields match the curated snapshot the picker shows before install")
    func declaredFieldsMatchTheCuratedCopy() {
        let declared = KafkaConnectionField.fields()
        let curated = PluginMetadataRegistry.shared
            .snapshot(forRegisteredTypeId: "Kafka")?
            .connection.additionalConnectionFields ?? []

        #expect(declared.isEmpty == false)
        #expect(declared.map(\.id).sorted() == curated.map(\.id).sorted())
        for field in declared {
            guard let match = curated.first(where: { $0.id == field.id }) else {
                Issue.record("the curated snapshot is missing \(field.id)")
                continue
            }
            #expect(match.label == field.label)
            #expect(match.isRequired == field.isRequired)
            #expect(match.defaultValue == field.defaultValue)
            #expect(match.section == field.section)
        }
    }
}
