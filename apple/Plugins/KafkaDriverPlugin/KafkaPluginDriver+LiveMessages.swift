import Foundation
import os
import TableProPluginKit

// Follows topics from each partition's end offset with plain Fetch requests and no consumer group, so it never
// joins a group or moves a group's committed offsets.
extension KafkaPluginDriver: PluginLiveMessaging {
    var liveMessageKind: PluginLiveMessageKind? { .topics }

    func subscribe(
        _ request: PluginLiveSubscriptionRequest,
        sessions: any PluginLiveSessionSource
    ) async throws -> any PluginLiveSubscription {
        guard let follower = try await sessions.openSession() as? KafkaPluginDriver else {
            throw KafkaError.notConnected
        }
        let cluster = follower.liveCluster
        var cursors: [KafkaFollowCursor] = []
        for topicName in request.channels {
            let metadata = try await cluster.metadata(topics: [topicName], refresh: true)
            let topic = try metadata.requireTopic(named: topicName)
            let partitions = topic.partitions.map(\.index).sorted()
            let ends = try await KafkaOffsetsRequest.listOffsets(
                topic: topicName,
                partitions: partitions,
                timestamp: KafkaOffsetsRequest.latestTimestamp,
                cluster: cluster
            )
            cursors += KafkaFollowCursor.cursors(topic: topicName, ends: ends)
        }
        return KafkaLiveSubscription(cluster: cluster, cursors: cursors)
    }
}

struct KafkaFollowCursor: Sendable, Equatable {
    let topic: String
    let partition: Int32
    let nextOffset: Int64

    static func cursors(topic: String, ends: [Int32: Int64]) -> [KafkaFollowCursor] {
        ends.keys.sorted().compactMap { partition in
            ends[partition].map { KafkaFollowCursor(topic: topic, partition: partition, nextOffset: $0) }
        }
    }

    static func message(from record: KafkaRecord, topic: String) -> PluginLiveMessage {
        PluginLiveMessage(
            timestamp: Date(timeIntervalSince1970: TimeInterval(record.timestamp) / 1_000),
            channel: topic,
            payload: text(record.value) ?? "",
            key: text(record.key),
            partition: Int(record.partition),
            offset: record.offset
        )
    }

    // A payload that is not UTF-8 reads as hex, the way the topic grid shows it.
    static func text(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8) ?? data.map { String(format: "%02X", $0) }.joined()
    }
}

final class KafkaLiveSubscription: PluginLiveSubscription, @unchecked Sendable {
    private static let recordsPerFetch = 500
    private static let logger = Logger(subsystem: "com.TablePro.KafkaDriver", category: "LiveMessages")

    let messages: AsyncThrowingStream<PluginLiveMessage, Error>
    private let cluster: KafkaCluster
    private let reader: Task<Void, Never>

    init(cluster: KafkaCluster, cursors: [KafkaFollowCursor]) {
        self.cluster = cluster
        let (stream, continuation) = AsyncThrowingStream<PluginLiveMessage, Error>.makeStream()
        messages = stream
        reader = Task {
            do {
                // Each Fetch waits up to 500 ms on the broker when the partition has nothing new, so no loop spins.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for cursor in cursors {
                        group.addTask {
                            var offset = cursor.nextOffset
                            while !Task.isCancelled {
                                let page = try await KafkaFetchRequest.fetch(
                                    topic: cursor.topic,
                                    partition: cursor.partition,
                                    startOffset: offset,
                                    maximumRecords: Self.recordsPerFetch,
                                    cluster: cluster
                                )
                                for record in page.records {
                                    continuation.yield(KafkaFollowCursor.message(from: record, topic: cursor.topic))
                                }
                                if let last = page.records.last { offset = last.offset + 1 }
                            }
                        }
                    }
                    // The first partition that fails ends the follow, and leaving the group cancels the others.
                    while try await group.next() != nil {}
                }
                continuation.finish()
            } catch {
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                Self.logger.info("Topic follow ended: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
                continuation.finish(throwing: error)
            }
        }
    }

    func publish(_ payload: String, to channel: String) async throws {
        let metadata = try await cluster.metadata(topics: [channel])
        let topic = try metadata.requireTopic(named: channel)
        guard let partition = topic.partitions.map(\.index).min() else { throw KafkaError.unknownTopic(channel) }
        _ = try await KafkaProduceRequest.produce(
            topic: channel,
            partition: partition,
            key: nil,
            value: Data(payload.utf8),
            headers: [],
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000),
            cluster: cluster
        )
    }

    func close() async {
        reader.cancel()
        _ = await reader.value
    }
}
