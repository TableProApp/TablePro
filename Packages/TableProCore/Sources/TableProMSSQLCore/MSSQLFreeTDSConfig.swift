//
//  MSSQLFreeTDSConfig.swift
//  TableProMSSQLCore
//
//  db-lib has no per-connection setting for encryption: dbsetlname refuses DBSETENCRYPT with error 20043 and
//  dbsetlbool leaves it unimplemented. The level, `ca file` and `check certificate hostname` exist only in
//  freetds.conf, so every connection describes its server as one entry of a file the driver owns; see
//  MSSQLFreeTDSConfigFile.
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

/// The `encryption` values libtds reads, which decide what the client offers in the TDS prelogin.
///
/// libtds also takes `off`, which tells the server the client cannot encrypt at all. It is left out: the password then
/// crosses the network in the clear, and a server that forces encryption drops the connection.
public enum MSSQLEncryptionLevel: String, CaseIterable, Equatable, Sendable {
    /// Encrypts the login, and the rest of the session only when the server forces encryption.
    case request
    /// Encrypts the whole session, and fails against a server that cannot.
    case require
}

public enum MSSQLFreeTDSConfigError: LocalizedError, Equatable, Sendable {
    case invalidPort(Int)
    case unreadableHost
    case unreadableAuthorityPath
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return String(format: String(localized: "%ld is not a TCP port."), port)
        case .unreadableHost:
            return String(localized: """
                The host cannot be passed to FreeTDS. Use a host name or an IP address, without spaces, brackets, \
                “=”, “;” or “#”.
                """)
        case .unreadableAuthorityPath:
            return String(localized: """
                The CA certificate path cannot be passed to FreeTDS. Use a shorter path, without “;”, “#” or \
                repeated spaces.
                """)
        case .unwritable(let detail):
            return String(format: String(localized: "The FreeTDS configuration could not be written: %@"), detail)
        }
    }
}

public enum MSSQLFreeTDSConfig {
    /// macOS ships the system roots as a PEM bundle, which is what FreeTDS wants. Without this a
    /// verifying mode would need a CA file from the user even for a public certificate authority.
    public static let systemTrustStorePath = "/etc/ssl/cert.pem"

    /// libtds reads freetds.conf a line at a time into a 256 byte buffer, so a longer line is cut.
    static let maximumLineLength = 255

    public static func authorityPath(userSupplied: String?) -> String {
        guard let userSupplied, !userSupplied.trimmingCharacters(in: .whitespaces).isEmpty else {
            return systemTrustStorePath
        }
        return userSupplied
    }
}

/// One server as libtds reads it from freetds.conf.
///
/// The entry is named after the host because db-lib sends the name dbopen was given as the server name in the login
/// packet, and that name has to stay the host. It states every option it depends on, even at libtds's own default: a
/// section called `global` holds the defaults for every other one, and a host can have that name. Every value is
/// checked against the way libtds reads the file: `;` and `#` start a comment, runs of white space collapse to one, a
/// `[` opens a section and `=` ends an option's name. A value that would read back differently is refused rather than
/// written.
public struct MSSQLFreeTDSServerEntry: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let encryption: MSSQLEncryptionLevel
    public let verification: MSSQLCertificateVerification
    public let authorityPath: String?

    public init(
        host: String,
        port: Int,
        encryption: MSSQLEncryptionLevel,
        verification: MSSQLCertificateVerification,
        caCertificatePath: String?
    ) throws {
        guard (1...65_535).contains(port) else {
            throw MSSQLFreeTDSConfigError.invalidPort(port)
        }
        guard Self.isReadableHost(host) else {
            throw MSSQLFreeTDSConfigError.unreadableHost
        }
        let authorityPath = verification.needsAuthority
            ? MSSQLFreeTDSConfig.authorityPath(userSupplied: caCertificatePath)
            : nil
        if let authorityPath, !Self.isReadableValue(authorityPath, option: "ca file") {
            throw MSSQLFreeTDSConfigError.unreadableAuthorityPath
        }
        self.host = host
        self.port = port
        self.encryption = encryption
        self.verification = verification
        self.authorityPath = authorityPath
    }

    public init(options: MSSQLConnectionOptions) throws {
        try self.init(
            host: options.host,
            port: options.port,
            encryption: options.encryptionLevel,
            verification: options.certificateVerification,
            caCertificatePath: options.caCertificatePath
        )
    }

    /// The server name dbopen is given, and the section libtds looks it up by.
    public var name: String { host }

    public var text: String {
        [
            "[\(name)]",
            "\thost = \(host)",
            "\tport = \(port)",
            "\ttds version = 7.4",
            "\tencryption = \(encryption.rawValue)",
            "\tca file = \(authorityPath ?? "")",
            "\tcheck certificate hostname = \(verification.checksHostname ? "yes" : "no")"
        ].joined(separator: "\n") + "\n"
    }

    private static let hostDelimiters = CharacterSet(charactersIn: "[]=;#")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)

    private static func isReadableHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.rangeOfCharacter(from: hostDelimiters) == nil else { return false }
        return fitsOnOneLine("[\(host)]") && fitsOnOneLine("\thost = \(host)")
    }

    private static func isReadableValue(_ value: String, option: String) -> Bool {
        guard value.rangeOfCharacter(from: CharacterSet(charactersIn: ";#").union(.controlCharacters)) == nil,
              value == value.trimmingCharacters(in: .whitespaces),
              !value.contains("  ")
        else { return false }
        return fitsOnOneLine("\t\(option) = \(value)")
    }

    private static func fitsOnOneLine(_ line: String) -> Bool {
        line.utf8.count <= MSSQLFreeTDSConfig.maximumLineLength
    }
}
