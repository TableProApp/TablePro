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
    case unreadableServicePrincipal
    case nameInUse(String)
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
        case .unreadableServicePrincipal:
            return String(localized: """
                The Kerberos service principal name for this server cannot be passed to FreeTDS. Connect through a \
                shorter host name.
                """)
        case .nameInUse(let name):
            return String(
                format: String(localized: """
                    Another connection to %@ with other settings is still logging in. Try again once it finishes.
                    """),
                name
            )
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
/// The section's name is the server name db-lib sends in the login packet, because dbopen is given that name and
/// libtds finds the section by it. For a host name it has to stay the host: FreeTDS sends no TLS server name, so an
/// Azure SQL gateway learns which server a login is for from this field alone. An IP address names no server a gateway
/// could route by, so there the port joins the name the way SQL Server writes one, `10.0.0.5,1433`, and connects to
/// other ports on one address, every SSH tunnel on 127.0.0.1 among them, never share a name.
///
/// The entry states every option it depends on, even at libtds's own default: a section called `global` holds the
/// defaults for every other one, and a host can have that name. Every value is checked against the way libtds reads the
/// file: `;` and `#` start a comment, runs of white space collapse to one, a `[` opens a section and `=` ends an
/// option's name. A value that would read back differently is refused rather than written.
public struct MSSQLFreeTDSServerEntry: Equatable, Sendable {
    /// The server name dbopen is given, and the section libtds looks it up by.
    public let name: String
    /// The host libtds dials, without the brackets an IPv6 address is often written in, which libtds drops too.
    public let host: String
    public let port: Int
    public let encryption: MSSQLEncryptionLevel
    public let verification: MSSQLCertificateVerification
    public let authorityPath: String?
    /// The Kerberos service principal libtds asks a ticket for. Without one it builds `MSSQLSvc/<host>:<port>` in the
    /// default realm. It is written here rather than set on the login, whose setter takes no more than 128 bytes.
    public let servicePrincipal: String?

    public init(
        host: String,
        port: Int,
        encryption: MSSQLEncryptionLevel,
        verification: MSSQLCertificateVerification,
        caCertificatePath: String?,
        servicePrincipal: String? = nil
    ) throws {
        guard (1...65_535).contains(port) else {
            throw MSSQLFreeTDSConfigError.invalidPort(port)
        }
        let dialled = Self.withoutBrackets(host)
        let name = Self.isNumericAddress(dialled) ? "\(dialled),\(port)" : dialled
        guard Self.isReadableHost(dialled), Self.fitsOnOneLine("[\(name)]") else {
            throw MSSQLFreeTDSConfigError.unreadableHost
        }
        let authorityPath = verification.needsAuthority
            ? MSSQLFreeTDSConfig.authorityPath(userSupplied: caCertificatePath)
            : nil
        if let authorityPath, !Self.isReadableValue(authorityPath, option: "ca file") {
            throw MSSQLFreeTDSConfigError.unreadableAuthorityPath
        }
        let principal = servicePrincipal.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if let principal, !Self.isReadableValue(principal, option: "spn") {
            throw MSSQLFreeTDSConfigError.unreadableServicePrincipal
        }
        self.name = name
        self.host = dialled
        self.port = port
        self.encryption = encryption
        self.verification = verification
        self.authorityPath = authorityPath
        self.servicePrincipal = principal
    }

    public init(options: MSSQLConnectionOptions) throws {
        try self.init(
            host: options.host,
            port: options.port,
            encryption: options.encryptionLevel,
            verification: options.certificateVerification,
            caCertificatePath: options.caCertificatePath,
            servicePrincipal: options.authMethod == .windows ? options.kerberosServicePrincipal : nil
        )
    }

    public var text: String {
        [
            "[\(name)]",
            "\thost = \(host)",
            "\tport = \(port)",
            "\ttds version = 7.4",
            "\tencryption = \(encryption.rawValue)",
            "\tca file = \(authorityPath ?? "")",
            "\tcheck certificate hostname = \(verification.checksHostname ? "yes" : "no")",
            "\tspn = \(servicePrincipal ?? "")"
        ].joined(separator: "\n") + "\n"
    }

    private static let hostDelimiters = CharacterSet(charactersIn: "[]=;#")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)

    private static func isReadableHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.rangeOfCharacter(from: hostDelimiters) == nil else { return false }
        return fitsOnOneLine("\thost = \(host)")
    }

    private static func withoutBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func isNumericAddress(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return false }
        freeaddrinfo(result)
        return true
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
