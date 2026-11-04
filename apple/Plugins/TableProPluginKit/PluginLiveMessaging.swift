import Foundation

// Messages that flow past a connection rather than being stored: notifications, pub/sub channels, topic tails.
public protocol PluginLiveMessaging: AnyObject, Sendable {
    // Synchronous so a menu can ask without I/O; nil means this driver cannot follow live messages.
    var liveMessageKind: PluginLiveMessageKind? { get }
    // Every driver the plugin takes from `sessions` is closed by the host once the subscription ends, so the person's
    // own session is never subscribed. Throws when a channel or topic cannot be followed.
    func subscribe(
        _ request: PluginLiveSubscriptionRequest,
        sessions: any PluginLiveSessionSource
    ) async throws -> any PluginLiveSubscription
}

public protocol PluginLiveSessionSource: Sendable {
    func openSession() async throws -> any PluginDatabaseDriver
}

// The host never overlaps two `publish` calls; `close()` may arrive at any time and ends `messages`.
public protocol PluginLiveSubscription: AnyObject, Sendable {
    // Finishes after `close()`; throws when the connection drops, and the host then subscribes again.
    var messages: AsyncThrowingStream<PluginLiveMessage, Error> { get }
    func publish(_ payload: String, to channel: String) async throws
    func close() async
}

public enum PluginLiveMessageKind: String, Sendable {
    // PostgreSQL LISTEN and NOTIFY.
    case notifications
    // Redis SUBSCRIBE, PSUBSCRIBE and PUBLISH.
    case pubSub
    // Kafka topics read from their end, without a consumer group.
    case topics
}

public struct PluginLiveSubscriptionRequest: Sendable, Equatable {
    public let channels: [String]
    // Glob patterns, on a kind that matches channels by pattern.
    public let patterns: [String]

    public init(channels: [String], patterns: [String] = []) {
        self.channels = channels
        self.patterns = patterns
    }
}

public struct PluginLiveMessage: Sendable, Equatable {
    // When the engine stamped it, or when it arrived when the engine stamps nothing.
    public let timestamp: Date
    public let channel: String
    // The pattern that matched, for a message a pattern subscription received.
    public let pattern: String?
    public let payload: String
    public let key: String?
    public let partition: Int?
    public let offset: Int64?

    public init(
        timestamp: Date,
        channel: String,
        pattern: String? = nil,
        payload: String,
        key: String? = nil,
        partition: Int? = nil,
        offset: Int64? = nil
    ) {
        self.timestamp = timestamp
        self.channel = channel
        self.pattern = pattern
        self.payload = payload
        self.key = key
        self.partition = partition
        self.offset = offset
    }
}
