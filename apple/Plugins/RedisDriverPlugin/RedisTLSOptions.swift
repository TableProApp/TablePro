import Foundation
import TableProPluginKit

nonisolated struct RedisTLSOptions: Equatable, Sendable {
    let serverName: String
    let verifiesCertificate: Bool
    let expectedHost: String?
    let caCertificatePath: String?
    let clientCertificatePath: String?
    let clientKeyPath: String?

    var checksHostname: Bool { expectedHost != nil }

    init(
        host: String,
        verifiesCertificate: Bool,
        verifiesHostname: Bool,
        caCertificatePath: String?,
        clientCertificatePath: String?,
        clientKeyPath: String?
    ) {
        serverName = host
        self.verifiesCertificate = verifiesCertificate
        expectedHost = verifiesCertificate && verifiesHostname ? host : nil
        self.caCertificatePath = verifiesCertificate ? Self.nonEmpty(caCertificatePath) : nil
        self.clientCertificatePath = Self.nonEmpty(clientCertificatePath)
        self.clientKeyPath = Self.nonEmpty(clientKeyPath)
    }

    // Through a tunnel's forward, SNI and the hostname check name the server behind it, not the dialed 127.0.0.1.
    static func make(sslConfig: SSLConfiguration, host: String, serverName: String? = nil) -> RedisTLSOptions? {
        guard sslConfig.isEnabled else { return nil }
        return RedisTLSOptions(
            host: serverName ?? host,
            verifiesCertificate: sslConfig.verifiesCertificate,
            verifiesHostname: sslConfig.verifiesHostname,
            caCertificatePath: sslConfig.caCertificatePath,
            clientCertificatePath: sslConfig.clientCertificatePath,
            clientKeyPath: sslConfig.clientKeyPath
        )
    }

    private static func nonEmpty(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
