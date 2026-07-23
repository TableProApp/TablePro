import Foundation

/// Builds the SQL Server Kerberos service principal name (SPN) with an explicit realm.
///
/// FreeTDS otherwise constructs an unrealmed `MSSQLSvc/host:port`, which macOS Heimdal resolves
/// against the client's `default_realm` with no cross-realm referral. Windows Authentication then
/// fails (`KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN`) whenever the SQL Server's realm differs from the Mac's
/// default realm. Supplying the realm-qualified SPN via `DBSETSERVERPRINCIPAL` makes Heimdal request
/// the service ticket from the correct realm.
public enum MSSQLKerberosSPN {
    /// Returns `MSSQLSvc/<host>:<port>@<REALM>`, or `nil` when no realm is set (letting FreeTDS keep
    /// its default, unrealmed SPN). The realm is upper-cased to match Active Directory convention.
    public static func build(host: String, port: Int, realm: String?) -> String? {
        guard let realm = realm?.trimmingCharacters(in: .whitespacesAndNewlines), !realm.isEmpty else {
            return nil
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }
        return "MSSQLSvc/\(trimmedHost):\(port)@\(realm.uppercased())"
    }
}
