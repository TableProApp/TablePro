import Foundation
import NIOSSL
import OracleNIO

public enum OracleTLSMapper {
    public static func tls(
        for description: OracleTLSDescription
    ) throws -> OracleNIO.OracleConnection.Configuration.TLS {
        guard description.mode != .disabled else { return .disable }

        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = certificateVerification(for: description.mode)

        if description.verifiesCertificate, let caCertificatePath = description.caCertificatePath {
            try requireReadableFile(at: caCertificatePath, field: .certificateAuthority)
            configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caCertificatePath))
        }
        if let clientCertificatePath = description.clientCertificatePath {
            try requireReadableFile(at: clientCertificatePath, field: .clientCertificate)
            let certificates = try NIOSSLCertificate.fromPEMFile(clientCertificatePath)
            configuration.certificateChain = certificates.map { .certificate($0) }
        }
        if let clientKeyPath = description.clientKeyPath {
            try requireReadableFile(at: clientKeyPath, field: .clientKey)
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: clientKeyPath, format: .pem))
        }

        return .require(try NIOSSLContext(configuration: configuration))
    }

    public static func certificateVerification(
        for mode: OracleTLSDescription.Mode
    ) -> CertificateVerification {
        switch mode {
        case .verifyIdentity: return .fullVerification
        case .verifyCA: return .noHostnameVerification
        case .required, .disabled: return .none
        }
    }

    private static func requireReadableFile(at path: String, field: OracleCertificateField) throws {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw OracleCoreError.certificateUnavailable(field: field, path: path)
        }
    }
}
