import CryptoKit
import Foundation

// Where a connection sends what it signs in with. An approval or a typed password holds only while this stays the same.
public struct ConnectionDestination: Equatable, Sendable {
    public struct Endpoint: Equatable, Sendable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int?, defaultPort: Int = 22) {
            self.host = host
            self.port = port ?? defaultPort
        }
    }

    // Preferred and Required both fall to an active attacker, so the two count as one.
    public enum Transport: String, Sendable {
        case unverified
        case verifyCA
        case verifyIdentity
    }

    // A linked SSH profile is named by the servers it dials, so moving the profile moves the destination.
    public enum Tunnel: Equatable, Sendable {
        case none
        case ssh(server: Endpoint, jumps: [Endpoint])
    }

    // Host-owned settings that change how a session behaves, never where it dials.
    public static let ignoredFieldKeys: Set<String> = [
        "binaryInlineLimitKB",
        "completionIdentifierCase",
        "connectTimeoutSeconds",
        "maskingRules",
        "postDisconnectScript",
        "preConnectScript",
        "promptForPassword",
        "queryTimeoutSeconds",
        "redisDatabase",
        "scriptTimeoutSeconds",
        "sslClientKeyPassphrase",
    ]

    public let type: String
    public let host: String
    public let port: Int
    public let transport: Transport
    public let tunnel: Tunnel
    public let fields: [String: String]

    public init(
        type: String,
        host: String,
        port: Int,
        transport: Transport,
        tunnel: Tunnel,
        additionalFields: [String: String]
    ) {
        self.type = type.lowercased()
        self.host = Self.normalizedHost(host)
        self.port = port
        self.transport = transport
        self.tunnel = tunnel
        var kept: [String: String] = [:]
        let routing = ConnectionSecretOptions.removingSecrets(from: additionalFields)
        for (key, value) in routing where !Self.ignoredFieldKeys.contains(key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                kept[key] = trimmed
            }
        }
        self.fields = kept
    }

    public var digest: String {
        var canonical = Data()
        for (key, value) in canonicalEntries {
            Self.append(key, to: &canonical)
            Self.append(value, to: &canonical)
        }
        let hash = SHA256.hash(data: canonical)
        return "v1:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    private var canonicalEntries: [(String, String)] {
        var entries: [(String, String)] = [
            ("type", type),
            ("host", host),
            ("port", String(port)),
            ("transport", transport.rawValue),
            ("tunnel", tunnelDescription),
        ]
        for key in fields.keys.sorted() {
            entries.append(("field." + key, fields[key] ?? ""))
        }
        return entries
    }

    private var tunnelDescription: String {
        switch tunnel {
        case .none:
            return "none"
        case .ssh(let server, let jumps):
            return ([server] + jumps)
                .map { Self.normalizedHost($0.host) + ":" + String($0.port) }
                .joined(separator: ",")
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Length-prefixed, so no value can forge the boundary of the next entry.
    private static func append(_ text: String, to data: inout Data) {
        let bytes = Data(text.utf8)
        data.append(contentsOf: String(bytes.count).utf8)
        data.append(UInt8(ascii: ":"))
        data.append(bytes)
    }
}
