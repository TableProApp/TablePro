//
//  MSSQLFreeTDSConfig.swift
//  TableProMSSQLCore
//
//  FreeTDS db-lib exposes no per-connection API for certificate validation: DBSETENCRYPT only
//  says whether to encrypt. The `ca file` and `check certificate hostname` settings live in
//  freetds.conf, so a connection that must verify writes its own one-entry config and points
//  FREETDSCONF at it for the duration of the dbopen call.
//

import Foundation

public enum MSSQLCertificateVerification: Equatable, Sendable {
    /// Encrypt without checking who is on the other end. What "Required" has always meant.
    case none
    /// Check that the server certificate chains to the given authority.
    case chain
    /// Check the chain and that the certificate names the host being dialled.
    case chainAndHostname

    public var checksHostname: Bool { self == .chainAndHostname }
    public var needsAuthority: Bool { self != .none }
}

public enum MSSQLFreeTDSConfig {
    /// The name the generated entry carries, and the name handed to dbopen in place of host:port.
    public static let serverEntryName = "TableProServer"

    /// macOS ships the system roots as a PEM bundle, which is what FreeTDS wants. Without this a
    /// verifying mode would need a CA file from the user even for a public certificate authority.
    public static let systemTrustStorePath = "/etc/ssl/cert.pem"

    public static func authorityPath(userSupplied: String?) -> String {
        guard let userSupplied, !userSupplied.trimmingCharacters(in: .whitespaces).isEmpty else {
            return systemTrustStorePath
        }
        return userSupplied
    }

    public static func configuration(
        host: String,
        port: Int,
        encryptionFlag: String,
        verification: MSSQLCertificateVerification,
        caCertificatePath: String?
    ) -> String {
        var lines = [
            "[\(serverEntryName)]",
            "\thost = \(host)",
            "\tport = \(port)",
            "\ttds version = 7.4",
            "\tencryption = \(encryptionFlag)",
        ]

        if verification.needsAuthority {
            lines.append("\tca file = \(authorityPath(userSupplied: caCertificatePath))")
        }
        if verification.checksHostname {
            lines.append("\tcheck certificate hostname = yes")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
