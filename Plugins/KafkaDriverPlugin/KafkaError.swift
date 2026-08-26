import Foundation
import TableProPluginKit

enum KafkaError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case truncatedResponse(needed: Int, available: Int)
    case malformedResponse(String)
    case unsupportedApiVersion(api: String, required: Int16, brokerRange: ClosedRange<Int16>?)
    case broker(code: Int16, api: String)
    case authenticationFailed(String)
    case unsupportedCompression(String)
    case decompressionFailed(codec: String, reason: String)
    case syntax(String)
    case unknownTopic(String)
    case producedToUnknownPartition(topic: String, partition: Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to the Kafka cluster.")
        case .connectionFailed(let detail):
            return String(format: String(localized: "Could not reach the Kafka cluster: %@"), detail)
        case .truncatedResponse(let needed, let available):
            return String(
                format: String(localized: "The broker's reply ended early: needed %d more bytes, had %d."),
                needed,
                available
            )
        case .malformedResponse(let detail):
            return String(format: String(localized: "Could not read the broker's reply: %@"), detail)
        case .unsupportedApiVersion(let api, let required, let range):
            guard let range else {
                return String(
                    format: String(localized: "This broker does not support the %@ request at all."),
                    api
                )
            }
            return String(
                format: String(localized: "This broker supports %@ v%d to v%d, and TablePro needs v%d."),
                api,
                Int(range.lowerBound),
                Int(range.upperBound),
                Int(required)
            )
        case .broker(let code, let api):
            return String(
                format: String(localized: "The broker rejected the %@ request: %@"),
                api,
                KafkaErrorCode.describe(code)
            )
        case .authenticationFailed(let detail):
            return String(format: String(localized: "Kafka authentication failed: %@"), detail)
        case .unsupportedCompression(let codec):
            return String(
                format: String(localized: "These messages use the %@ compression codec, which TablePro cannot read."),
                codec
            )
        case .decompressionFailed(let codec, let reason):
            return String(
                format: String(localized: "Could not decompress a %@ batch: %@"),
                codec,
                reason
            )
        case .syntax(let detail):
            return detail
        case .unknownTopic(let name):
            return String(format: String(localized: "No topic named %@ on this cluster."), name)
        case .producedToUnknownPartition(let topic, let partition):
            return String(
                format: String(localized: "Topic %@ has no partition %d."),
                topic,
                Int(partition)
            )
        }
    }
}

/// The subset of Kafka's error codes this client can meet, with the retryable ones marked.
/// A code that is not listed still reports its number rather than being swallowed.
enum KafkaErrorCode {
    static let none: Int16 = 0
    static let offsetOutOfRange: Int16 = 1
    static let unknownTopicOrPartition: Int16 = 3
    static let leaderNotAvailable: Int16 = 5
    static let notLeaderOrFollower: Int16 = 6
    static let requestTimedOut: Int16 = 7
    static let messageTooLarge: Int16 = 10
    static let coordinatorLoadInProgress: Int16 = 14
    static let coordinatorNotAvailable: Int16 = 15
    static let notCoordinator: Int16 = 16
    static let illegalSaslState: Int16 = 34
    static let unsupportedVersion: Int16 = 35
    static let topicAuthorizationFailed: Int16 = 29
    static let groupAuthorizationFailed: Int16 = 30
    static let clusterAuthorizationFailed: Int16 = 31
    static let saslAuthenticationFailed: Int16 = 58
    static let unknownTopicId: Int16 = 100
    static let fencedLeaderEpoch: Int16 = 74
    static let unknownLeaderEpoch: Int16 = 75

    /// The codes that mean the cluster moved rather than that the request was wrong. These are
    /// the only ones worth one metadata refresh and a retry; everything else is a real answer,
    /// and retrying it just delays the error the user needs to see.
    static func requiresMetadataRefresh(_ code: Int16) -> Bool {
        switch code {
        case leaderNotAvailable, notLeaderOrFollower, unknownTopicOrPartition,
             unknownTopicId, fencedLeaderEpoch, unknownLeaderEpoch:
            return true
        default:
            return false
        }
    }

    static func describe(_ code: Int16) -> String {
        switch code {
        case offsetOutOfRange:
            return String(localized: "the requested offset is outside the partition's range")
        case unknownTopicOrPartition:
            return String(localized: "unknown topic or partition")
        case leaderNotAvailable:
            return String(localized: "the partition leader is not available")
        case notLeaderOrFollower:
            return String(localized: "this broker no longer leads the partition")
        case requestTimedOut:
            return String(localized: "the request timed out on the broker")
        case messageTooLarge:
            return String(localized: "the message is larger than the broker accepts")
        case coordinatorLoadInProgress:
            return String(localized: "the group coordinator is still loading")
        case coordinatorNotAvailable:
            return String(localized: "the group coordinator is not available")
        case notCoordinator:
            return String(localized: "this broker does not coordinate that group")
        case illegalSaslState:
            return String(localized: "the connection is not ready for authentication")
        case unsupportedVersion:
            return String(localized: "the broker does not support this request version")
        case topicAuthorizationFailed:
            return String(localized: "not authorized for this topic")
        case groupAuthorizationFailed:
            return String(localized: "not authorized for this consumer group")
        case clusterAuthorizationFailed:
            return String(localized: "not authorized for this cluster operation")
        case saslAuthenticationFailed:
            return String(localized: "the credentials were rejected")
        case unknownTopicId:
            return String(localized: "unknown topic id")
        default:
            return String(format: String(localized: "error code %d"), Int(code))
        }
    }

    static func check(_ code: Int16, api: String) throws {
        guard code != none else { return }
        if code == saslAuthenticationFailed || code == illegalSaslState {
            throw KafkaError.authenticationFailed(describe(code))
        }
        throw KafkaError.broker(code: code, api: api)
    }
}
