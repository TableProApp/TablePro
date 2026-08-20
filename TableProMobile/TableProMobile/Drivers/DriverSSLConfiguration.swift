import Foundation
import TableProModels
import TableProOracleCore

nonisolated struct DriverSSLConfiguration: Equatable, Sendable {
    let mode: SSLConfiguration.SSLMode
    let caCertificatePath: String?
    let clientCertificatePath: String?
    let clientKeyPath: String?

    static let disabled = DriverSSLConfiguration(mode: .disable)

    init(
        mode: SSLConfiguration.SSLMode,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    init(sslEnabled: Bool, configuration: SSLConfiguration?) {
        guard let configuration else {
            mode = sslEnabled ? .require : .disable
            caCertificatePath = nil
            clientCertificatePath = nil
            clientKeyPath = nil
            return
        }
        mode = configuration.mode
        caCertificatePath = configuration.caCertificatePath
        clientCertificatePath = configuration.clientCertificatePath
        clientKeyPath = configuration.clientKeyPath
    }

    func applying(_ materialized: MaterializedCertificates) -> DriverSSLConfiguration {
        DriverSSLConfiguration(
            mode: mode,
            caCertificatePath: materialized.caCertificatePath ?? caCertificatePath,
            clientCertificatePath: materialized.clientCertificatePath ?? clientCertificatePath,
            clientKeyPath: materialized.clientKeyPath ?? clientKeyPath
        )
    }

    var isEnabled: Bool { mode != .disable }
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyFull }
    var verifiesHostname: Bool { mode == .verifyFull }

    var postgresSSLMode: String {
        switch mode {
        case .disable: return "disable"
        case .require: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyFull: return "verify-full"
        }
    }

    var freetdsEncryptionFlag: String {
        switch mode {
        case .disable: return "off"
        case .require, .verifyCa, .verifyFull: return "require"
        }
    }

    var oracleTLSDescription: OracleTLSDescription {
        OracleTLSDescription(
            mode: oracleMode,
            caCertificatePath: caCertificatePath,
            clientCertificatePath: clientCertificatePath,
            clientKeyPath: clientKeyPath
        )
    }

    private var oracleMode: OracleTLSDescription.Mode {
        switch mode {
        case .disable: return .disabled
        case .require: return .required
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
