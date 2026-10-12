import Foundation

public extension TLSClientIdentityError {
    func message(certificatePath: String, keyPath: String) -> String {
        switch self {
        case .certificateFileUnreadable:
            return String(format: String(localized: "The client certificate at %@ could not be read."), certificatePath)
        case .keyFileUnreadable:
            return String(format: String(localized: "The client key at %@ could not be read."), keyPath)
        case .certificateUnreadable:
            return String(
                format: String(localized: "The client certificate at %@ could not be read as a PEM or DER certificate."),
                certificatePath
            )
        case .keyUnreadable:
            return String(
                format: String(localized: "The client key at %@ is not an RSA or EC private key in PEM or DER form."),
                keyPath
            )
        case .keyEncrypted:
            return String(
                format: String(localized: "The client key at %@ is encrypted. This connection needs an unencrypted key."),
                keyPath
            )
        case .keyDoesNotMatchCertificate:
            return String(
                format: String(localized: "The client key at %1$@ does not belong to the certificate at %2$@."),
                keyPath,
                certificatePath
            )
        }
    }
}
