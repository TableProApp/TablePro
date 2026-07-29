import Foundation

/// Decides whether a realm resolved from the system Kerberos configuration is worth overriding
/// FreeTDS's default service principal with.
///
/// macOS Heimdal never consults `default_realm` when it maps a host to a realm. With no matching
/// `[domain_realm]` entry it synthesizes the DNS domain after the first label, upper-cased, so a
/// correct `default_realm` would be replaced by a guess derived from DNS. That guess breaks the
/// setups where the realm and the DNS domain differ (disjoint namespaces, CNAME aliases, hosts
/// whose service principal lives in the forest root), which authenticate today.
///
/// Only a realm that carries more than the host's own domain came from the Kerberos configuration,
/// and only that one is safe to send. This matches the JDBC driver, which maps a host through
/// `[domain_realm]` and otherwise falls back to `default_realm`.
public enum MSSQLKerberosRealm {
    public static func domainGuess(forHost host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstDot = trimmed.firstIndex(of: ".") else { return nil }
        let domain = trimmed[trimmed.index(after: firstDot)...]
        return domain.isEmpty ? nil : domain.uppercased()
    }

    public static func isConfigured(_ realm: String, forHost host: String) -> Bool {
        let trimmedRealm = realm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRealm.isEmpty else { return false }
        guard let domainGuess = domainGuess(forHost: host) else { return true }
        return trimmedRealm.caseInsensitiveCompare(domainGuess) != .orderedSame
    }
}
