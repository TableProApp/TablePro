import Foundation

public enum KerberosFailureKind: Sendable, Equatable {
    case noCredential
    case principalUnknown
    case wrongPassword
    case spnNotFound
    case clockSkew
    case realmNotResolved
    case ticketExpired
}

// FreeTDS, libpq and Connector/C each pass the GSS mechanism's own text through in their errors.
// The macOS GSS framework reports a KDC error by its e-text, such as CLIENT_NOT_FOUND, where MIT
// prints the error table's sentence.
public enum KerberosFailureClassifier {
    public static func classify(_ message: String) -> KerberosFailureKind? {
        let lower = message.lowercased()
        if lower.contains("clock skew") {
            return .clockSkew
        }
        if lower.contains("ticket expired") || lower.contains("credentials have expired") {
            return .ticketExpired
        }
        if lower.contains("no credentials cache") || lower.contains("no valid credentials")
            || lower.contains("no credential") || lower.contains("no kerberos credentials")
            || lower.contains("credential for asked mech-type mech not found") {
            return .noCredential
        }
        if lower.contains("preauthentication failed") || lower.contains("password incorrect")
            || lower.contains("integrity check failed") {
            return .wrongPassword
        }
        if lower.contains("client not found in kerberos database")
            || lower.contains("client's entry in database has expired") || lower.contains("client_not_found") {
            return .principalUnknown
        }
        if lower.contains("server not found in kerberos database") || lower.contains("looking_up_server") {
            return .spnNotFound
        }
        if lower.contains("cannot find kdc") || lower.contains("cannot resolve network address")
            || lower.contains("unable to reach any kdc") || lower.contains("cannot determine realm")
            || lower.contains("cannot locate default realm") {
            return .realmNotResolved
        }
        return nil
    }
}
