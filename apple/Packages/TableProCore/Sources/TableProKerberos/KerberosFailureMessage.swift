import Foundation
import TableProCoreTypes

public enum KerberosFailureMessage {
    // Each engine registers its service principal differently, so it names that case itself.
    public static func describe(
        kind: KerberosFailureKind,
        serverMessage: String,
        spnNotFound: (summary: String, suggestion: String)
    ) -> String {
        let summary: String
        let suggestion: String
        switch kind {
        case .noCredential:
            summary = String(localized: "No Kerberos ticket was found.")
            suggestion = String(localized: "Run kinit user@REALM.COM in Terminal, or enter a Kerberos principal and password, then reconnect.")
        case .principalUnknown:
            summary = String(localized: "The Kerberos principal is unknown to the domain.")
            suggestion = String(localized: "Check the principal spelling and realm, for example user@REALM.COM with the realm in uppercase.")
        case .wrongPassword:
            summary = String(localized: "The Kerberos password was rejected.")
            suggestion = String(localized: "Re-enter the domain password for this principal.")
        case .spnNotFound:
            summary = spnNotFound.summary
            suggestion = spnNotFound.suggestion
        case .clockSkew:
            summary = String(localized: "This Mac's clock is too far out of sync with the domain controller.")
            suggestion = String(localized: "Turn on Set time automatically in System Settings > General > Date & Time, then reconnect.")
        case .realmNotResolved:
            summary = String(localized: "The Kerberos realm could not be resolved.")
            suggestion = String(localized: "Confirm this network resolves the domain, or add the realm to /etc/krb5.conf.")
        case .ticketExpired:
            summary = String(localized: "The Kerberos ticket has expired.")
            suggestion = String(localized: "Run kinit user@REALM.COM to renew it, then reconnect.")
        }
        return "\(summary) \(suggestion) (\(serverMessage))"
    }
}
