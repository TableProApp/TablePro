import Foundation

enum KafkaSASLMechanism: String, Sendable, CaseIterable {
    case plain = "PLAIN"
    case scramSHA256 = "SCRAM-SHA-256"
    case scramSHA512 = "SCRAM-SHA-512"

    var wireName: String { rawValue }
}

struct KafkaCredentials: Sendable {
    let mechanism: KafkaSASLMechanism?
    let username: String
    let password: String
}
