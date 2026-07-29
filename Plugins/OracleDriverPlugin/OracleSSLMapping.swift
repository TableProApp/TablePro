import Foundation
import Logging
import NIOSSL
import OracleNIO
import OSLog
import TableProPluginKit

private let osLogger = Logger(subsystem: "com.TablePro.OracleDriver", category: "OracleSSLMapping")

enum OracleSSLMapping {
    static func tls(for sslConfig: SSLConfiguration) throws -> OracleNIO.OracleConnection.Configuration.TLS {
        switch sslConfig.mode {
        case .disabled:
            return .disable
        case .preferred:
            osLogger.warning("Oracle SSL mode 'Preferred' is not supported by OracleNIO; falling back to plain TCP. Use 'Required' to enforce TCPS.")
            return .disable
        case .required, .verifyCa, .verifyIdentity:
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = certificateVerification(for: sslConfig.mode)
            if sslConfig.verifiesCertificate, !sslConfig.caCertificatePath.isEmpty {
                let caCerts = try NIOSSLCertificate.fromPEMFile(sslConfig.caCertificatePath)
                tlsConfiguration.trustRoots = .certificates(caCerts)
            }
            if !sslConfig.clientCertificatePath.isEmpty {
                let clientCerts = try NIOSSLCertificate.fromPEMFile(sslConfig.clientCertificatePath)
                tlsConfiguration.certificateChain = clientCerts.map { .certificate($0) }
            }
            if !sslConfig.clientKeyPath.isEmpty {
                let key = try NIOSSLPrivateKey(file: sslConfig.clientKeyPath, format: .pem)
                tlsConfiguration.privateKey = .privateKey(key)
            }
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            return .require(sslContext)
        }
    }

    static func certificateVerification(for mode: SSLMode) -> CertificateVerification {
        switch mode {
        case .verifyIdentity: return .fullVerification
        case .verifyCa: return .noHostnameVerification
        case .required, .preferred, .disabled: return .none
        }
    }
}
