//
//  MySQLClientArguments.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The arguments a mysql-family client takes, which depend on which family it belongs to.
///
/// MySQL and MariaDB no longer share an SSL surface. Measured, MariaDB 12.3.3 answers
/// `--ssl-mode=PREFERRED` with `unknown variable 'ssl-mode=PREFERRED'` and exit 7, and MySQL
/// 8.4.11 answers `--ssl` with `unknown option '--ssl'` and exit 2. Every mapping here was measured
/// against a MariaDB server with TLS off, a MariaDB server with a self-signed certificate and a
/// MySQL server with its own, using both client families.
enum MySQLClientArguments {
    /// | mode | MySQL | MariaDB |
    /// | --- | --- | --- |
    /// | disabled | `--ssl-mode=DISABLED` | `--skip-ssl` |
    /// | preferred | `--ssl-mode=PREFERRED` | `--ssl --skip-ssl-verify-server-cert` |
    /// | required | `--ssl-mode=REQUIRED` | `--ssl --ssl-verify-server-cert` |
    /// | verifyCa | `--ssl-mode=VERIFY_CA` | `--ssl --ssl-verify-server-cert` |
    /// | verifyIdentity | `--ssl-mode=VERIFY_IDENTITY` | `--ssl --ssl-verify-server-cert` |
    ///
    /// `required` is the one that takes an argument. MariaDB has no flag for "encrypt and do not
    /// verify": measured, `--ssl` on its own falls back to plaintext against a server without TLS
    /// and reports success, which is the silent cleartext dump the mode exists to prevent. Only
    /// `--ssl-verify-server-cert` refuses that server. It is not the stricter choice it reads as:
    /// with no `--ssl-ca` given, MariaDB 12.3.3 accepted a server whose certificate said
    /// `CN=totally.other.invalid`, so the flag requires TLS rather than an identity, and the
    /// identity check is what `--ssl-ca` adds. MariaDB has no hostname-only tier, so `verifyCa` and
    /// `verifyIdentity` reach it the same way.
    static func tls(_ ssl: SSLConfiguration, flavor: NativeDumpToolFlavor, toolPath: String) throws -> [String] {
        guard ssl.isEnabled else {
            return disabledFlags(flavor: flavor)
        }
        return try modeFlags(ssl.mode, flavor: flavor, toolPath: toolPath) + certificateFlags(ssl)
    }

    /// Everything the connection holds beyond the mode. The certificate implies `--ssl` on MariaDB,
    /// so none of it is sent for a connection whose SSL is off, whatever the form left behind.
    private static func certificateFlags(_ ssl: SSLConfiguration) -> [String] {
        var flags: [String] = []
        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            flags.append("--ssl-ca=\(ssl.caCertificatePath)")
        }
        if !ssl.clientCertificatePath.isEmpty {
            flags.append("--ssl-cert=\(ssl.clientCertificatePath)")
        }
        if !ssl.clientKeyPath.isEmpty {
            flags.append("--ssl-key=\(ssl.clientKeyPath)")
        }
        return flags
    }

    private static func disabledFlags(flavor: NativeDumpToolFlavor) -> [String] {
        switch flavor {
        case .mysql: return ["--ssl-mode=DISABLED"]
        case .mariadb: return ["--skip-ssl"]
        case .unidentified: return []
        }
    }

    private static func modeFlags(
        _ mode: SSLMode,
        flavor: NativeDumpToolFlavor,
        toolPath: String
    ) throws -> [String] {
        switch flavor {
        case .mysql:
            return [mysqlSSLMode(mode)]
        case .mariadb:
            return mode == .preferred
                ? ["--ssl", "--skip-ssl-verify-server-cert"]
                : ["--ssl", "--ssl-verify-server-cert"]
        case .unidentified:
            guard mode == .preferred else { throw unidentifiedToolError(toolPath) }
            return []
        }
    }

    /// A tool that answered nothing is not guessed at for a mode that promises encryption: picking
    /// the wrong family's spelling either fails the dump or, for the flag MariaDB accepts and
    /// ignores, sends it in cleartext.
    private static func unidentifiedToolError(_ toolPath: String) -> NativeDumpError {
        .incompatibleTool(
            message: String(
                format: String(
                    localized: """
                        TablePro could not tell whether %@ is MySQL's client or MariaDB's. They take \
                        different SSL options, and it will not guess for a connection that asks for \
                        an encrypted one. Reinstall the client tools and try again.
                        """),
                toolPath
            )
        )
    }

    static func mysqlSSLMode(_ mode: SSLMode) -> String {
        switch mode {
        case .disabled: return "--ssl-mode=DISABLED"
        case .preferred: return "--ssl-mode=PREFERRED"
        case .required: return "--ssl-mode=REQUIRED"
        case .verifyCa: return "--ssl-mode=VERIFY_CA"
        case .verifyIdentity: return "--ssl-mode=VERIFY_IDENTITY"
        }
    }

    /// `mysqldump` 8.0 and newer read `information_schema.COLUMN_STATISTICS`, which no MariaDB
    /// server and no MySQL server before 8.0 has. Measured against MariaDB 12.3.3: the dump stops
    /// on `Unknown table 'column_statistics' in information_schema (1109)` and exits 2 having
    /// written part of the file. With this flag it exits 0.
    ///
    /// Backup only. MariaDB's own dump tool does not know the flag, and neither restore client
    /// takes it.
    static func dumpCompatibility(tool: NativeDumpResolvedTool, serverVersion: String?) -> [String] {
        guard tool.flavor == .mysql else { return [] }
        guard let major = MySQLDumpToolIdentifier.majorVersion(fromVersionText: tool.versionText), major >= 8 else {
            return []
        }
        guard !serverHasColumnStatistics(serverVersion) else { return [] }
        return ["--skip-column-statistics"]
    }

    /// Answered from the server's own banner, and `true` when it cannot be read, so an unknown
    /// server keeps the argument list it has always had.
    static func serverHasColumnStatistics(_ serverVersion: String?) -> Bool {
        guard let serverVersion, !serverVersion.isEmpty else { return true }
        guard !serverVersion.lowercased().contains("mariadb") else { return false }
        guard let major = Int(serverVersion.prefix { $0.isNumber }) else { return true }
        return major >= 8
    }
}
