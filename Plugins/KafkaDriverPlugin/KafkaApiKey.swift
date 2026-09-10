import Foundation

struct KafkaUUID: Hashable, Sendable {
    let bytes: [UInt8]

    static let zero = KafkaUUID(bytes: [UInt8](repeating: 0, count: 16))

    init(bytes: [UInt8]) {
        self.bytes = bytes.count == 16 ? bytes : [UInt8](repeating: 0, count: 16)
    }

    var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    var uuidString: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [0 ..< 8, 8 ..< 12, 12 ..< 16, 16 ..< 20, 20 ..< 32]
        return groups
            .map { String(hex[hex.index(hex.startIndex, offsetBy: $0.lowerBound) ..< hex.index(hex.startIndex, offsetBy: $0.upperBound)]) }
            .joined(separator: "-")
    }
}

enum KafkaApiKey: Int16, CaseIterable, Sendable {
    case produce = 0
    case fetch = 1
    case listOffsets = 2
    case metadata = 3
    case offsetFetch = 9
    case findCoordinator = 10
    case describeGroups = 15
    case listGroups = 16
    case saslHandshake = 17
    case apiVersions = 18
    case deleteRecords = 21
    case describeConfigs = 32
    case saslAuthenticate = 36

    var name: String {
        switch self {
        case .produce: return "Produce"
        case .fetch: return "Fetch"
        case .listOffsets: return "ListOffsets"
        case .metadata: return "Metadata"
        case .offsetFetch: return "OffsetFetch"
        case .findCoordinator: return "FindCoordinator"
        case .describeGroups: return "DescribeGroups"
        case .listGroups: return "ListGroups"
        case .saslHandshake: return "SaslHandshake"
        case .apiVersions: return "ApiVersions"
        case .deleteRecords: return "DeleteRecords"
        case .describeConfigs: return "DescribeConfigs"
        case .saslAuthenticate: return "SaslAuthenticate"
        }
    }

    /// The version at and above which the request and response bodies use compact encoding and
    /// carry tagged fields. `nil` means the API never became flexible.
    ///
    /// SaslHandshake is the trap here: it is declared `flexibleVersions: none` at both v0 and
    /// v1, so it stays legacy forever even though the APIs either side of it went flexible.
    /// Encoding it compactly is a silent authentication failure rather than a parse error.
    var firstFlexibleVersion: Int16? {
        switch self {
        case .produce: return 9
        case .fetch: return 12
        case .listOffsets: return 6
        case .metadata: return 9
        case .offsetFetch: return 6
        case .findCoordinator: return 3
        case .describeGroups: return 5
        case .listGroups: return 3
        case .apiVersions: return 3
        case .deleteRecords: return 2
        case .describeConfigs: return 4
        case .saslAuthenticate: return 2
        case .saslHandshake: return nil
        }
    }

    /// The highest version this client implements. Every one of these still addresses topics
    /// by NAME: Fetch v13, Metadata v13 and Produce v10 switch to a 16-byte topic UUID
    /// (KIP-516), which is a different request shape rather than a bigger one.
    var highestImplementedVersion: Int16 {
        switch self {
        case .produce: return 9
        case .fetch: return 12
        case .listOffsets: return 7
        case .metadata: return 12
        case .offsetFetch: return 8
        case .findCoordinator: return 4
        case .describeGroups: return 5
        case .listGroups: return 4
        case .saslHandshake: return 1
        case .apiVersions: return 3
        case .deleteRecords: return 2
        case .describeConfigs: return 4
        case .saslAuthenticate: return 2
        }
    }

    /// The lowest version this client can still speak. Kafka 4.x removed the oldest versions
    /// of several APIs, and older brokers cap the newest, so a usable range needs both ends.
    var lowestImplementedVersion: Int16 {
        switch self {
        case .produce: return 3
        case .fetch: return 4
        case .listOffsets: return 1
        case .metadata: return 1
        case .offsetFetch: return 1
        case .findCoordinator: return 0
        case .describeGroups: return 0
        case .listGroups: return 0
        case .saslHandshake: return 0
        case .apiVersions: return 0
        case .deleteRecords: return 0
        case .describeConfigs: return 1
        case .saslAuthenticate: return 0
        }
    }

    func isFlexible(version: Int16) -> Bool {
        guard let first = firstFlexibleVersion else { return false }
        return version >= first
    }
}

/// What the broker said it supports, per API key. Built once per connection from ApiVersions
/// and then consulted for every request, so a request is never sent at a version the broker
/// would reject with UNSUPPORTED_VERSION and an unhelpfully empty body.
struct KafkaApiVersionTable: Sendable {
    private var ranges: [Int16: ClosedRange<Int16>] = [:]

    init(ranges: [Int16: ClosedRange<Int16>]) {
        self.ranges = ranges
    }

    /// Used before ApiVersions has been exchanged, and for a broker so old it does not answer
    /// ApiVersions at all: assume only what every supported broker has.
    static let preNegotiation = KafkaApiVersionTable(ranges: [:])

    func brokerRange(for api: KafkaApiKey) -> ClosedRange<Int16>? {
        ranges[api.rawValue]
    }

    /// The highest version both sides implement.
    func negotiated(_ api: KafkaApiKey) throws -> Int16 {
        guard let range = ranges[api.rawValue] else {
            guard ranges.isEmpty else {
                throw KafkaError.unsupportedApiVersion(api: api.name, required: api.lowestImplementedVersion, brokerRange: nil)
            }
            return api.lowestImplementedVersion
        }
        let ceiling = min(range.upperBound, api.highestImplementedVersion)
        guard ceiling >= range.lowerBound, ceiling >= api.lowestImplementedVersion else {
            throw KafkaError.unsupportedApiVersion(
                api: api.name,
                required: api.lowestImplementedVersion,
                brokerRange: range
            )
        }
        return ceiling
    }

}
