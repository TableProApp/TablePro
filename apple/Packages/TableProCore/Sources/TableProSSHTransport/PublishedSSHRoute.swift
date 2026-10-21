import CryptoKit
import Foundation

// The route a Mac dialed for a connection after reading its ~/.ssh/config, published so a device
// without that file reaches the same hops. `basis` hashes the tunnel input the route was dialed
// from: once that input changes, the route no longer describes it and is ignored.
public struct PublishedSSHRoute: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public struct Hop: Codable, Hashable, Sendable {
        public var id: UUID
        public var alias: String
        public var host: String
        public var port: Int
        public var username: String

        public init(id: UUID, alias: String, host: String, port: Int, username: String) {
            self.id = id
            self.alias = alias
            self.host = host
            self.port = port
            self.username = username
        }
    }

    public struct Target: Codable, Hashable, Sendable {
        public var alias: String
        public var host: String
        public var port: Int
        public var username: String

        public init(alias: String, host: String, port: Int, username: String) {
            self.alias = alias
            self.host = host
            self.port = port
            self.username = username
        }
    }

    public struct Input: Hashable, Sendable {
        // The id is part of the input: a hop deleted and typed again has a new one, and the route's
        // copy of the old id would point at a key this device no longer uses.
        public struct JumpHost: Hashable, Sendable {
            public var id: UUID
            public var host: String
            public var port: Int?
            public var username: String

            public init(id: UUID, host: String, port: Int?, username: String) {
                self.id = id
                self.host = host
                self.port = port
                self.username = username
            }
        }

        public var host: String
        public var port: Int?
        public var username: String
        public var jumpHosts: [JumpHost]

        public init(host: String, port: Int?, username: String, jumpHosts: [JumpHost]) {
            self.host = host
            self.port = port
            self.username = username
            self.jumpHosts = jumpHosts
        }
    }

    public var version: Int
    public var publisher: UUID
    public var basis: String
    public var hops: [Hop]
    public var target: Target

    public init(publisher: UUID, input: Input, hops: [Hop], target: Target) {
        self.version = Self.currentVersion
        self.publisher = publisher
        self.basis = Self.basis(of: input)
        self.hops = hops
        self.target = target
    }

    public static let defaultPort = 22

    public func describes(_ input: Input) -> Bool {
        version == Self.currentVersion && basis == Self.basis(of: input)
    }

    public func leadsToSameHosts(as other: PublishedSSHRoute) -> Bool {
        version == other.version && basis == other.basis && hops == other.hops && target == other.target
    }

    // True when dialing the input as typed reaches the same hosts, so there is nothing to publish.
    public func addsNothing(to input: Input) -> Bool {
        guard target.host == input.host,
              target.port == (input.port ?? Self.defaultPort),
              target.username == input.username,
              hops.count == input.jumpHosts.count
        else { return false }
        return zip(hops, input.jumpHosts).allSatisfy { hop, typed in
            hop.host == typed.host && hop.port == (typed.port ?? Self.defaultPort) && hop.username == typed.username
        }
    }

    // Built by hand rather than by JSONEncoder, whose escaping differs between the Foundation
    // releases the two apps run on; a basis that changed with the OS would hide every route.
    public static func basis(of input: Input) -> String {
        var canonical = "v1"
        func append(_ value: String) {
            canonical += "|\(value.utf8.count):\(value)"
        }
        func append(_ port: Int?) {
            canonical += "|" + (port.map(String.init) ?? "-")
        }
        append(input.host)
        append(input.port)
        append(input.username)
        canonical += "|\(input.jumpHosts.count)"
        for hop in input.jumpHosts {
            append(hop.id.uuidString)
            append(hop.host)
            append(hop.port)
            append(hop.username)
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // A hop that only ~/.ssh/config names has no id of its own. Deriving one from its alias keeps
    // the key another device bound to it across republishes.
    public static func derivedHopId(alias: String, occurrence: Int) -> UUID {
        let seed = "ssh-route-hop|\(alias.utf8.count):\(alias)|\(occurrence)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func decoded(from data: Data) -> PublishedSSHRoute? {
        try? JSONDecoder().decode(PublishedSSHRoute.self, from: data)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}
