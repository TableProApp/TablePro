import Foundation

public enum MSSQLKerberosClassifier {
    public static func classify(_ message: String) -> MSSQLKerberosFailureKind? {
        let lower = message.lowercased()
        if lower.contains("clock skew") {
            return .clockSkew
        }
        if lower.contains("ticket expired") || lower.contains("credentials have expired") {
            return .ticketExpired
        }
        if lower.contains("no credentials cache") || lower.contains("no valid credentials")
            || lower.contains("no credential") {
            return .noCredential
        }
        if lower.contains("preauthentication failed") || lower.contains("password incorrect")
            || lower.contains("integrity check failed") {
            return .wrongPassword
        }
        if lower.contains("client not found in kerberos database")
            || lower.contains("client's entry in database has expired") {
            return .principalUnknown
        }
        if lower.contains("server not found in kerberos database") {
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
