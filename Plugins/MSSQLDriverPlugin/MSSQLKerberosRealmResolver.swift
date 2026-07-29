import Foundation
import GSS
import TableProMSSQLCore

/// Resolves the canonical SQL Server Kerberos service (host + realm) for a connection host.
///
/// macOS Heimdal does not apply the system Kerberos configuration (`[domain_realm]`) when FreeTDS
/// builds its own SPN string, so a cross-realm host fails with `KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN`.
/// We resolve the realm here (like the JDBC driver) and hand FreeTDS an explicit SPN via
/// `DBSETSERVERPRINCIPAL`.
///
/// Once an explicit SPN is set, FreeTDS stops canonicalizing a short hostname to its FQDN (which it
/// otherwise does with `getaddrinfo` for dot-less names). To avoid regressing those connections we
/// perform the same canonicalization here, so the SPN carries the FQDN the service is registered
/// under, short name or CNAME included.
enum MSSQLKerberosRealmResolver {
    /// Canonical host and realm for `host`, or `nil` when the realm is unresolved or Heimdal only
    /// guessed it from the host's own DNS domain. The caller then leaves the SPN to FreeTDS, whose
    /// unrealmed principal resolves against `default_realm`.
    static func canonicalService(forHost host: String) -> (host: String, realm: String)? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonicalHost = canonicalHostname(trimmed)
        guard let realm = realm(forHost: canonicalHost),
              MSSQLKerberosRealm.isConfigured(realm, forHost: canonicalHost)
        else { return nil }
        return (host: canonicalHost, realm: realm)
    }

    /// Mirrors FreeTDS: canonicalize a dot-less (short) hostname to its FQDN via `getaddrinfo`.
    /// A name that already contains a dot is used as-is, matching FreeTDS's own behavior.
    private static func canonicalHostname(_ host: String) -> String {
        guard !host.contains(".") else { return host }
        var hints = addrinfo()
        hints.ai_flags = AI_CANONNAME
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return host }
        defer { freeaddrinfo(result) }
        if let canonical = result.pointee.ai_canonname {
            let name = String(cString: canonical)
            if name.contains(".") { return name }
        }
        return host
    }

    /// Realm for a host from the system Kerberos configuration (`[domain_realm]`, `default_realm`),
    /// via GSS name canonicalization, the same resolution the KDC clients use.
    private static func realm(forHost host: String) -> String? {
        var minor: OM_uint32 = 0
        guard let cString = strdup("MSSQLSvc@\(host)") else { return nil }
        var nameBuffer = gss_buffer_desc(length: strlen(cString), value: cString)
        var importedName: gss_name_t?
        let importStatus = gss_import_name(
            &minor, &nameBuffer, &__gss_c_nt_hostbased_service_oid_desc, &importedName
        )
        free(cString)
        guard importStatus == GSS_S_COMPLETE, let importedName else { return nil }
        defer {
            var releaseMinor: OM_uint32 = 0
            var releasable: gss_name_t? = importedName
            _ = gss_release_name(&releaseMinor, &releasable)
        }

        var canonicalName: gss_name_t?
        let canonStatus = gss_canonicalize_name(
            &minor, importedName, &__gss_krb5_mechanism_oid_desc, &canonicalName
        )
        guard canonStatus == GSS_S_COMPLETE, let canonicalName else { return nil }
        defer {
            var releaseMinor: OM_uint32 = 0
            var releasable: gss_name_t? = canonicalName
            _ = gss_release_name(&releaseMinor, &releasable)
        }

        var displayBuffer = gss_buffer_desc()
        var nameType: gss_OID?
        let displayStatus = gss_display_name(&minor, canonicalName, &displayBuffer, &nameType)
        defer {
            var releaseMinor: OM_uint32 = 0
            _ = gss_release_buffer(&releaseMinor, &displayBuffer)
        }
        guard displayStatus == GSS_S_COMPLETE, let value = displayBuffer.value else { return nil }

        let display = String(data: Data(bytes: value, count: displayBuffer.length), encoding: .utf8) ?? ""
        guard let atIndex = display.lastIndex(of: "@") else { return nil }
        let realm = String(display[display.index(after: atIndex)...])
        return realm.isEmpty ? nil : realm
    }
}
