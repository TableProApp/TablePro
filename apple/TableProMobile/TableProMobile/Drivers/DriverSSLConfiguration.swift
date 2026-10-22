import Foundation
import TableProModels
import TableProMSSQLCore
import TableProOracleCore
import TableProPluginKit

nonisolated struct DriverSSLConfiguration: Equatable, Sendable {
    let mode: TableProModels.SSLConfiguration.SSLMode
    let caCertificatePath: String?
    let clientCertificatePath: String?
    let clientKeyPath: String?
    // The Mac's Preferred: TLS when the server offers it, plaintext when it does not.
    let isPreferred: Bool
    // The name the certificate must carry when the dialed host is a tunnel's loopback.
    var serverName: String?

    static let disabled = DriverSSLConfiguration(mode: .disable)

    static let oracleVerifyCaUnavailableMessage = String(localized: """
        Verify CA needs a CA certificate, and an Oracle connection on this device cannot use one. Set SSL \
        Mode to Verify Identity to check the server's certificate and hostname against the system trust store.
        """)

    init(
        mode: TableProModels.SSLConfiguration.SSLMode,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil,
        isPreferred: Bool = false,
        serverName: String? = nil
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.isPreferred = isPreferred && mode == .require
        self.serverName = serverName
    }

    init(sslEnabled: Bool, configuration: TableProModels.SSLConfiguration?) {
        guard let configuration else {
            mode = sslEnabled ? .require : .disable
            caCertificatePath = nil
            clientCertificatePath = nil
            clientKeyPath = nil
            isPreferred = false
            return
        }
        mode = configuration.mode
        caCertificatePath = configuration.caCertificatePath
        clientCertificatePath = configuration.clientCertificatePath
        clientKeyPath = configuration.clientKeyPath
        isPreferred = configuration.isMacPreferred
    }

    func applying(_ materialized: MaterializedCertificates) -> DriverSSLConfiguration {
        DriverSSLConfiguration(
            mode: mode,
            caCertificatePath: materialized.caCertificatePath ?? caCertificatePath,
            clientCertificatePath: materialized.clientCertificatePath ?? clientCertificatePath,
            clientKeyPath: materialized.clientKeyPath ?? clientKeyPath,
            isPreferred: isPreferred,
            serverName: serverName
        )
    }

    var isEnabled: Bool { mode != .disable }
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyFull }
    var verifiesHostname: Bool { mode == .verifyFull }

    var postgresSSLMode: String {
        switch mode {
        case .disable: return "disable"
        case .require: return isPreferred ? "prefer" : "require"
        case .verifyCa: return "verify-ca"
        case .verifyFull: return "verify-full"
        }
    }

    var mssqlEncryptionLevel: MSSQLEncryptionLevel {
        switch mode {
        case .disable: return .request
        case .require: return isPreferred ? .request : .require
        case .verifyCa, .verifyFull: return .require
        }
    }

    var pluginConfiguration: TableProPluginKit.SSLConfiguration {
        TableProPluginKit.SSLConfiguration(
            mode: pluginMode,
            caCertificatePath: caCertificatePath ?? "",
            clientCertificatePath: clientCertificatePath ?? "",
            clientKeyPath: clientKeyPath ?? ""
        )
    }

    private var pluginMode: TableProPluginKit.SSLMode {
        switch mode {
        case .disable: return .disabled
        case .require: return isPreferred ? .preferred : .required
        case .verifyCa: return .verifyCa
        case .verifyFull: return .verifyIdentity
        }
    }

    var oracleTLSDescription: OracleTLSDescription {
        OracleTLSDescription(
            mode: oracleMode,
            caCertificatePath: caCertificatePath,
            clientCertificatePath: clientCertificatePath,
            clientKeyPath: clientKeyPath,
            serverName: serverName
        )
    }

    // OracleNIO has no TLS-or-plaintext mode, so Preferred dials plain TCP as on the Mac.
    private var oracleMode: OracleTLSDescription.Mode {
        switch mode {
        case .disable: return .disabled
        case .require: return isPreferred ? .disabled : .required
        case .verifyCa: return .verifyCA
        case .verifyFull: return .verifyIdentity
        }
    }

    var existingCACertificatePath: String? {
        guard verifiesCertificate else { return nil }
        return Self.existingPath(caCertificatePath)
    }

    var existingClientCertificatePath: String? {
        Self.existingPath(clientCertificatePath)
    }

    var existingClientKeyPath: String? {
        Self.existingPath(clientKeyPath)
    }

    private static func existingPath(_ path: String?) -> String? {
        guard let path,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
