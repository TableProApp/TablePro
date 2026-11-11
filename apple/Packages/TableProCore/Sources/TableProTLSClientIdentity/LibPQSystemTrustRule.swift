//
//  LibPQSystemTrustRule.swift
//  TableProTLSClientIdentity
//

import Foundation

// One rule for the driver and for pg_dump and pg_restore, so a session and its backup trust the same roots.
public enum LibPQSystemTrustRule {
    // Verify Identity with no CA file, over TCP, with no root file the user named for libpq.
    public static func usesSystemTrustAnchors(
        verifiesHostname: Bool,
        caCertificatePath: String,
        host: String,
        environment: [String: String],
        fileExists: (String) -> Bool
    ) -> Bool {
        // libpq opens no TLS on a socket, and an empty host is its default socket.
        guard verifiesHostname, caCertificatePath.isEmpty, !host.isEmpty, !host.hasPrefix("/") else { return false }
        if let named = environment["PGSSLROOTCERT"], !named.isEmpty { return false }
        return !fileExists(defaultRootCertificatePath(environment: environment))
    }

    // libpq reads HOME first and the password database only when it is unset or empty.
    public static func defaultRootCertificatePath(environment: [String: String]) -> String {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".postgresql", isDirectory: true)
            .appendingPathComponent("root.crt")
            .path
    }
}
