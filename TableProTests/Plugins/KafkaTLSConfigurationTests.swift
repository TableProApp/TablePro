import Foundation
import NIOCore
import NIOPosix
import TableProPluginKit
import Testing

struct KafkaTLSConfigurationTests {
    private let refusedEndpoint = KafkaEndpoint(host: "127.0.0.1", port: 1)

    private func isRefusal(_ error: KafkaError?) -> Bool {
        guard case .verifyCaNeedsCertificate? = error else { return false }
        return true
    }

    @Test("Verify CA with an empty or blank CA path is refused")
    func verifyCaWithoutCertificateIsRefused() {
        #expect(isRefusal(KafkaConnection.tlsConfigurationError(for: SSLConfiguration(mode: .verifyCa))))
        #expect(isRefusal(KafkaConnection.tlsConfigurationError(
            for: SSLConfiguration(mode: .verifyCa, caCertificatePath: "   ")
        )))
    }

    @Test("Verify CA with a CA path, and every other mode, passes the check")
    func otherConfigurationsPassTheCheck() {
        #expect(KafkaConnection.tlsConfigurationError(
            for: SSLConfiguration(mode: .verifyCa, caCertificatePath: "/certs/ca.pem")
        ) == nil)
        #expect(KafkaConnection.tlsConfigurationError(for: SSLConfiguration(mode: .verifyIdentity)) == nil)
        #expect(KafkaConnection.tlsConfigurationError(for: SSLConfiguration(mode: .required)) == nil)
        #expect(KafkaConnection.tlsConfigurationError(for: SSLConfiguration(mode: .preferred)) == nil)
        #expect(KafkaConnection.tlsConfigurationError(for: SSLConfiguration(mode: .disabled)) == nil)
    }

    @Test("The refusal names the missing CA and does not claim the cluster was unreachable")
    func refusalMessageIsItsOwn() {
        let message = KafkaError.verifyCaNeedsCertificate.errorDescription ?? ""
        #expect(message.contains("CA certificate"))
        #expect(!message.contains("Could not reach the Kafka cluster"))
    }

    @Test("A cluster with Verify CA and no CA refuses before dialing any bootstrap server")
    func clusterRefusesBeforeDialing() async {
        let cluster = KafkaCluster(
            bootstrap: [refusedEndpoint],
            ssl: SSLConfiguration(mode: .verifyCa),
            credentials: KafkaCredentials(mechanism: nil, username: "", password: ""),
            routing: .advertised,
            connectTimeoutSeconds: 1
        )
        let error = await #expect(throws: KafkaError.self) {
            try await cluster.connect()
        }
        #expect(isRefusal(error))
    }

    @Test("A broker connection with Verify CA and no CA refuses before opening a socket")
    func connectionRefusesBeforeOpeningASocket() async {
        let connection = KafkaConnection(endpoint: refusedEndpoint, clientId: "tablepro-tests")
        let error = await #expect(throws: KafkaError.self) {
            try await connection.open(
                ssl: SSLConfiguration(mode: .verifyCa),
                credentials: KafkaCredentials(mechanism: nil, username: "", password: ""),
                group: NIOSingletons.posixEventLoopGroup,
                timeout: .seconds(1)
            )
        }
        #expect(isRefusal(error))
    }

    @Test("Verify Identity with no CA still dials the broker")
    func verifyIdentityWithoutCertificateStillDials() async {
        let connection = KafkaConnection(endpoint: refusedEndpoint, clientId: "tablepro-tests")
        let error = await #expect(throws: KafkaError.self) {
            try await connection.open(
                ssl: SSLConfiguration(mode: .verifyIdentity),
                credentials: KafkaCredentials(mechanism: nil, username: "", password: ""),
                group: NIOSingletons.posixEventLoopGroup,
                timeout: .seconds(1)
            )
        }
        guard case .connectionFailed? = error else {
            Issue.record("expected a dial failure, got \(String(describing: error))")
            return
        }
    }
}
