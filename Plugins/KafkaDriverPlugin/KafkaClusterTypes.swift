import Foundation

struct KafkaEndpoint: Hashable, Sendable {
    let host: String
    let port: Int

    var description: String { "\(host):\(port)" }

    /// Parses `host:port`, tolerating a bare host and an IPv6 literal in brackets.
    static func parse(_ text: String, defaultPort: Int) -> KafkaEndpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
            let rest = trimmed[trimmed.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort
            return KafkaEndpoint(host: host, port: port)
        }
        guard let separator = trimmed.lastIndex(of: ":"),
              let port = Int(trimmed[trimmed.index(after: separator)...]) else {
            return KafkaEndpoint(host: trimmed, port: defaultPort)
        }
        return KafkaEndpoint(host: String(trimmed[trimmed.startIndex ..< separator]), port: port)
    }
}

/// Where broker traffic is allowed to go after Metadata names the cluster's members.
enum KafkaBrokerRouting: String, Sendable {
    /// Dial each partition leader at the address Metadata advertises. Correct on a flat network.
    case advertised
    /// Send everything to the bootstrap endpoint and never dial an advertised address.
    case bootstrapOnly

    static func resolve(_ raw: String?) -> KafkaBrokerRouting {
        guard let raw, let value = KafkaBrokerRouting(rawValue: raw) else { return .advertised }
        return value
    }
}

struct KafkaBroker: Sendable {
    let nodeId: Int32
    let endpoint: KafkaEndpoint
    let rack: String?
}

struct KafkaPartition: Sendable {
    let index: Int32
    let leader: Int32
    let replicas: [Int32]
    let inSyncReplicas: [Int32]
    let errorCode: Int16
}

struct KafkaTopic: Sendable {
    let name: String
    let topicId: KafkaUUID
    let isInternal: Bool
    let partitions: [KafkaPartition]
    let errorCode: Int16
}

struct KafkaClusterMetadata: Sendable {
    let brokers: [KafkaBroker]
    let controllerId: Int32
    let clusterId: String?
    let topics: [KafkaTopic]

    func topic(named name: String) -> KafkaTopic? {
        topics.first { $0.name == name }
    }
}
