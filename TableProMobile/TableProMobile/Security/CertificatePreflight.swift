import Foundation

nonisolated enum CertificateRequirement: String, Equatable, Sendable {
    case certificateAuthority
    case clientCertificate
    case clientKey
}

nonisolated enum CertificatePreflightError: Error, LocalizedError, Equatable {
    case fileMissing(CertificateRequirement)
    case clientCertificateWithoutKey
    case clientKeyWithoutCertificate

    var errorDescription: String? {
        switch self {
        case .fileMissing(.certificateAuthority):
            return String(localized: "The CA certificate for this connection is missing. Import it again in the connection's SSL settings.")
        case .fileMissing(.clientCertificate):
            return String(localized: "The client certificate for this connection is missing. Import it again in the connection's SSL settings.")
        case .fileMissing(.clientKey):
            return String(localized: "The client key for this connection is missing. Import it again in the connection's SSL settings.")
        case .clientCertificateWithoutKey:
            return String(localized: "This connection has a client certificate but no private key. Import both.")
        case .clientKeyWithoutCertificate:
            return String(localized: "This connection has a client key but no certificate. Import both.")
        }
    }
}

nonisolated enum CertificatePreflight {
    static func validate(_ ssl: DriverSSLConfiguration) throws {
        guard ssl.isEnabled else { return }

        if isConfigured(ssl.caCertificatePath), ssl.existingCACertificatePath == nil, ssl.verifiesCertificate {
            throw CertificatePreflightError.fileMissing(.certificateAuthority)
        }
        if isConfigured(ssl.clientCertificatePath), ssl.existingClientCertificatePath == nil {
            throw CertificatePreflightError.fileMissing(.clientCertificate)
        }
        if isConfigured(ssl.clientKeyPath), ssl.existingClientKeyPath == nil {
            throw CertificatePreflightError.fileMissing(.clientKey)
        }

        let hasCertificate = ssl.existingClientCertificatePath != nil
        let hasKey = ssl.existingClientKeyPath != nil
        if hasCertificate, !hasKey {
            throw CertificatePreflightError.clientCertificateWithoutKey
        }
        if hasKey, !hasCertificate {
            throw CertificatePreflightError.clientKeyWithoutCertificate
        }
    }

    private static func isConfigured(_ path: String?) -> Bool {
        guard let path else { return false }
        return !path.isEmpty
    }
}
