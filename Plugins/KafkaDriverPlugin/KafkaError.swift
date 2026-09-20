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
    case unknownGroup(String)
    case producedToUnknownPartition(topic: String, partition: Int32)
    case unknownPartitions(topic: String, partitions: [Int32], available: [Int32])
    case partitionsRejected(topic: String, partitions: [Int32], api: String, code: Int16)
    case partitionsUnanswered(topic: String, partitions: [Int32], api: String)
    case brokerUnreachable(nodeId: Int32, address: String, reason: String)
    case partitionsLedElsewhere(topic: String, partitions: [Int32])
    case partitionsHaveNoLeader(topic: String, partitions: [Int32])

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
        case .unknownGroup(let name):
            return String(format: String(localized: "No consumer group named %@ on this cluster."), name)
        case .producedToUnknownPartition(let topic, let partition):
            return String(
                format: String(localized: "Topic %@ has no partition %d."),
                topic,
                Int(partition)
            )
        case .unknownPartitions(let topic, let partitions, let available):
            return String(
                format: String(localized: "Topic %@ has no partition %@. It has %@."),
                topic,
                KafkaPartitionList.describe(partitions),
                KafkaPartitionList.describe(available)
            )
        case .partitionsRejected(let topic, let partitions, let api, let code):
            return String(
                format: String(localized: "The broker rejected %@ for partition %@ of %@: %@"),
                api,
                KafkaPartitionList.describe(partitions),
                topic,
                KafkaErrorCode.describe(code)
            )
        case .partitionsUnanswered(let topic, let partitions, let api):
            return String(
                format: String(localized: "The broker's %@ reply left out partition %@ of %@."),
                api,
                KafkaPartitionList.describe(partitions),
                topic
            )
        case .brokerUnreachable(let nodeId, let address, let reason):
            return String(
                format: String(localized: "Broker %d advertises %@, which could not be reached: %@"),
                Int(nodeId),
                address,
                reason
            )
        case .partitionsLedElsewhere(let topic, let partitions):
            return String(
                format: String(localized: """
                Partition %@ of %@ is led by another broker, and Broker Addresses is set to use only the \
                bootstrap address.
                """),
                KafkaPartitionList.describe(partitions),
                topic
            )
        case .partitionsHaveNoLeader(let topic, let partitions):
            return String(
                format: String(localized: "Partition %@ of %@ has no elected leader."),
                KafkaPartitionList.describe(partitions),
                topic
            )
        }
    }
}

/// Renders a partition set for a message.
///
/// A routing failure is about a set of partitions rather than one, and "partitions 1, 4, 5" is
/// what tells a user the request was split and which part of it failed. Sorted, because the
/// set arrives from a dictionary and an error that reorders itself between runs reads as noise.
enum KafkaPartitionList {
    static func describe(_ partitions: [Int32]) -> String {
        partitions.sorted().map(String.init).joined(separator: ", ")
    }
}

/// What to do about an error code before giving it to the user.
enum KafkaRetryAction: Sendable {
    /// A real answer. Report it.
    case report
    /// The client's view of the cluster is stale. Re-read Metadata, re-resolve the leader, retry.
    case resolveLeaderAgain
    /// The client's view of the group's coordinator is stale. Re-run FindCoordinator, retry.
    case findCoordinatorAgain
    /// Transient on the broker that answered. Retry the same request there.
    case retrySameBroker
}

/// The subset of Kafka's error codes this client can meet, with what to do about each.
/// A code that is not listed still reports its number rather than being swallowed.
enum KafkaErrorCode {
    static let none: Int16 = 0
    static let offsetOutOfRange: Int16 = 1
    static let unknownTopicOrPartition: Int16 = 3
    static let leaderNotAvailable: Int16 = 5
    static let notLeaderOrFollower: Int16 = 6
    static let requestTimedOut: Int16 = 7
    static let brokerNotAvailable: Int16 = 8
    static let replicaNotAvailable: Int16 = 9
    static let messageTooLarge: Int16 = 10
    static let networkException: Int16 = 13
    static let coordinatorLoadInProgress: Int16 = 14
    static let coordinatorNotAvailable: Int16 = 15
    static let notCoordinator: Int16 = 16
    static let illegalSaslState: Int16 = 34
    static let unsupportedVersion: Int16 = 35
    static let notController: Int16 = 41
    static let topicAuthorizationFailed: Int16 = 29
    static let groupAuthorizationFailed: Int16 = 30
    static let clusterAuthorizationFailed: Int16 = 31
    static let kafkaStorageError: Int16 = 56
    static let saslAuthenticationFailed: Int16 = 58
    /// 72 is LISTENER_NOT_FOUND and 73 is TOPIC_DELETION_DISABLED, which is the opposite of what
    /// this file said until #2993. Nothing read the constant, so nothing broke; the two are
    /// spelled out here because a hand-transcribed code table is exactly the thing that drifts.
    static let listenerNotFound: Int16 = 72
    static let topicDeletionDisabled: Int16 = 73
    static let fencedLeaderEpoch: Int16 = 74
    static let unknownLeaderEpoch: Int16 = 75
    static let offsetNotAvailable: Int16 = 78
    static let unknownTopicId: Int16 = 100

    /// What a code means for the request that drew it.
    ///
    /// Three outcomes rather than one boolean, because "retry" alone is not an instruction: a
    /// moved leader needs a fresh Metadata read before the retry can go anywhere different, a
    /// moved coordinator needs a fresh FindCoordinator, and a transient failure needs neither
    /// and would only be delayed by them. 8 BROKER_NOT_AVAILABLE is deliberately not retried:
    /// Kafka does not classify it retriable, and a client that retries it hides a broker that
    /// is genuinely down.
    static func retryAction(for code: Int16) -> KafkaRetryAction {
        switch code {
        case unknownTopicOrPartition, leaderNotAvailable, notLeaderOrFollower, replicaNotAvailable,
             networkException, kafkaStorageError, listenerNotFound, fencedLeaderEpoch,
             unknownLeaderEpoch, unknownTopicId:
            return .resolveLeaderAgain
        case coordinatorLoadInProgress, coordinatorNotAvailable, notCoordinator:
            return .findCoordinatorAgain
        case requestTimedOut, offsetNotAvailable:
            return .retrySameBroker
        default:
            return .report
        }
    }

    /// True when the code proves the broker did not take the request, so sending it again
    /// cannot repeat work the broker already did.
    ///
    /// The distinction only matters for a write. `KafkaProduceRequest` asks for
    /// `acks = -1`, and REQUEST_TIMED_OUT there means the leader appended the record and the
    /// in-sync replicas did not acknowledge in time; the same is true of a connection that
    /// broke and of a log directory that failed mid-append. This client sends no producer id,
    /// so Kafka cannot deduplicate a replay and the message is appended twice. The codes below
    /// all mean the broker refused the request outright, which is safe to send elsewhere.
    static func provesRequestWasNotApplied(_ code: Int16) -> Bool {
        switch code {
        case unknownTopicOrPartition, leaderNotAvailable, notLeaderOrFollower, replicaNotAvailable,
             listenerNotFound, fencedLeaderEpoch, unknownLeaderEpoch, unknownTopicId:
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
        case brokerNotAvailable:
            return String(localized: "the broker is not available")
        case replicaNotAvailable:
            return String(localized: "the replica is not available on this broker")
        case messageTooLarge:
            return String(localized: "the message is larger than the broker accepts")
        case networkException:
            return String(localized: "the connection to the broker broke")
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
        case notController:
            return String(localized: "this broker is not the cluster controller")
        case kafkaStorageError:
            return String(localized: "the broker could not read the partition's log directory")
        case saslAuthenticationFailed:
            return String(localized: "the credentials were rejected")
        case listenerNotFound:
            return String(localized: "the broker has no listener for this connection's security protocol")
        case topicDeletionDisabled:
            return String(localized: "topic deletion is disabled on this cluster")
        case fencedLeaderEpoch:
            return String(localized: "the partition's leader epoch has moved on")
        case unknownLeaderEpoch:
            return String(localized: "the broker has not caught up to the partition's leader epoch")
        case offsetNotAvailable:
            return String(localized: "the offset is not available on this broker yet")
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
