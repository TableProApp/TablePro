import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// The parts of Kafka request routing that can be decided without a broker.
///
/// Everything here failed silently on a multi-broker cluster and could not fail at all on a
/// single-broker one, which is why issue #2993 survived a full integration suite: with one
/// broker every partition's leader and every group's coordinator is the broker the client is
/// already holding, so a driver that routes nothing is indistinguishable from a correct one.
struct KafkaRoutingTests {
    // MARK: - Error code classification

    /// The constants are a hand transcription of Kafka's own table and nothing at runtime checks
    /// them, so the two that were transposed are pinned by number.
    @Test("72 is LISTENER_NOT_FOUND and 73 is TOPIC_DELETION_DISABLED")
    func listenerAndDeletionCodesAreNotTransposed() {
        #expect(KafkaErrorCode.listenerNotFound == 72)
        #expect(KafkaErrorCode.topicDeletionDisabled == 73)
    }

    @Test("A code that says the cluster moved asks for a fresh leader")
    func staleMetadataCodesResolveTheLeaderAgain() {
        let stale: [Int16] = [
            KafkaErrorCode.unknownTopicOrPartition,
            KafkaErrorCode.leaderNotAvailable,
            KafkaErrorCode.notLeaderOrFollower,
            KafkaErrorCode.replicaNotAvailable,
            KafkaErrorCode.networkException,
            KafkaErrorCode.kafkaStorageError,
            KafkaErrorCode.listenerNotFound,
            KafkaErrorCode.fencedLeaderEpoch,
            KafkaErrorCode.unknownLeaderEpoch,
            KafkaErrorCode.unknownTopicId
        ]
        for code in stale {
            #expect(KafkaErrorCode.retryAction(for: code) == .resolveLeaderAgain, "code \(code)")
        }
    }

    @Test("A coordinator code asks for a fresh coordinator, not a fresh leader")
    func coordinatorCodesFindTheCoordinatorAgain() {
        let coordinator: [Int16] = [
            KafkaErrorCode.coordinatorLoadInProgress,
            KafkaErrorCode.coordinatorNotAvailable,
            KafkaErrorCode.notCoordinator
        ]
        for code in coordinator {
            #expect(KafkaErrorCode.retryAction(for: code) == .findCoordinatorAgain, "code \(code)")
        }
    }

    /// A broker that is genuinely down is not a stale-metadata problem, and retrying it hides
    /// the outage behind a slower failure. Kafka does not classify it retriable either.
    @Test("A broker that is down and a real answer are both reported, not retried")
    func nonRetriableCodesAreReported() {
        #expect(KafkaErrorCode.retryAction(for: KafkaErrorCode.brokerNotAvailable) == .report)
        #expect(KafkaErrorCode.retryAction(for: KafkaErrorCode.offsetOutOfRange) == .report)
        #expect(KafkaErrorCode.retryAction(for: KafkaErrorCode.topicAuthorizationFailed) == .report)
        #expect(KafkaErrorCode.retryAction(for: KafkaErrorCode.none) == .report)
    }

    @Test("A transient code is retried where it is, without re-reading metadata")
    func transientCodesRetryTheSameBroker() {
        #expect(KafkaErrorCode.retryAction(for: KafkaErrorCode.requestTimedOut) == .retrySameBroker)
        #expect(KafkaErrorCode.retryAction(for: KafkaErrorCode.offsetNotAvailable) == .retrySameBroker)
    }

    // MARK: - Repeating a request

    /// A read can always be sent again. The retry exists for it.
    @Test("A read is retried on every code that says the cluster moved")
    func aReadRetriesEveryMovedCode() {
        for code in [KafkaErrorCode.notLeaderOrFollower, KafkaErrorCode.leaderNotAvailable,
                     KafkaErrorCode.requestTimedOut, KafkaErrorCode.networkException,
                     KafkaErrorCode.kafkaStorageError, KafkaErrorCode.offsetNotAvailable] {
            #expect(KafkaRequestRepeatability.safeToRepeat.allowsRetry(after: code), "code \(code)")
        }
    }

    /// A Produce asks for acks = -1 and sends no producer id, so REQUEST_TIMED_OUT can mean the
    /// leader appended the record and its replicas were late acknowledging it. Sending it again
    /// writes the message twice, with nothing on the cluster able to tell that it was one
    /// message.
    @Test("A write is not repeated on a code that leaves the outcome unknown")
    func aWriteIsNotRepeatedWhenTheOutcomeIsUnknown() {
        let ambiguous = [
            KafkaErrorCode.requestTimedOut,
            KafkaErrorCode.networkException,
            KafkaErrorCode.kafkaStorageError,
            KafkaErrorCode.offsetNotAvailable
        ]
        for code in ambiguous {
            #expect(!KafkaRequestRepeatability.onlyWhenBrokerRefusedIt.allowsRetry(after: code), "code \(code)")
            #expect(!KafkaErrorCode.provesRequestWasNotApplied(code), "code \(code)")
        }
    }

    /// The codes that mean the broker turned the request away are safe for a write, and they
    /// are the ones that carry the reported bug.
    @Test("A write is repeated when the broker refused it outright")
    func aWriteIsRepeatedWhenRefused() {
        let refused = [
            KafkaErrorCode.notLeaderOrFollower,
            KafkaErrorCode.leaderNotAvailable,
            KafkaErrorCode.unknownTopicOrPartition,
            KafkaErrorCode.replicaNotAvailable,
            KafkaErrorCode.listenerNotFound,
            KafkaErrorCode.fencedLeaderEpoch,
            KafkaErrorCode.unknownLeaderEpoch,
            KafkaErrorCode.unknownTopicId
        ]
        for code in refused {
            #expect(KafkaRequestRepeatability.onlyWhenBrokerRefusedIt.allowsRetry(after: code), "code \(code)")
        }
    }

    @Test("Neither kind repeats a real answer")
    func neitherKindRepeatsARealAnswer() {
        for code in [KafkaErrorCode.offsetOutOfRange, KafkaErrorCode.topicAuthorizationFailed,
                     KafkaErrorCode.brokerNotAvailable] {
            #expect(!KafkaRequestRepeatability.safeToRepeat.allowsRetry(after: code), "code \(code)")
            #expect(!KafkaRequestRepeatability.onlyWhenBrokerRefusedIt.allowsRetry(after: code), "code \(code)")
        }
    }

    // MARK: - Collecting per-partition answers

    @Test("Every partition answering gives every partition's value")
    func everyPartitionAnswers() throws {
        let outcomes: [Int32: KafkaPartitionOutcome<Int64>] = [
            0: .value(10), 1: .value(20), 2: .value(30)
        ]
        let values = try KafkaPartitionOutcome.requireAll(
            outcomes,
            topic: "orders",
            api: "ListOffsets",
            routing: .advertised
        )
        #expect(values == [0: 10, 1: 20, 2: 30])
    }

    /// The shape of #2993: a broker answers for the partitions it leads and rejects the rest in
    /// the same reply. The rejection has to name the partitions rather than being reported as
    /// though the whole request failed.
    @Test("A rejected partition names itself in the error")
    func aRejectedPartitionNamesItself() {
        let outcomes: [Int32: KafkaPartitionOutcome<Int64>] = [
            0: .value(10),
            1: .rejected(code: KafkaErrorCode.notLeaderOrFollower),
            2: .rejected(code: KafkaErrorCode.notLeaderOrFollower)
        ]
        do {
            _ = try KafkaPartitionOutcome.requireAll(
                outcomes,
                topic: "orders",
                api: "ListOffsets",
                routing: .advertised
            )
            Issue.record("expected the rejected partitions to be reported")
        } catch let error as KafkaError {
            guard case .partitionsRejected(let topic, let partitions, let api, let code) = error else {
                Issue.record("expected partitionsRejected, got \(error)")
                return
            }
            #expect(topic == "orders")
            #expect(partitions.sorted() == [1, 2])
            #expect(api == "ListOffsets")
            #expect(code == KafkaErrorCode.notLeaderOrFollower)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func rejectionCode(_ outcomes: [Int32: KafkaPartitionOutcome<Int64>]) -> Int16? {
        do {
            _ = try KafkaPartitionOutcome.requireAll(
                outcomes,
                topic: "orders",
                api: "ListOffsets",
                routing: .advertised
            )
            Issue.record("expected a rejection")
            return nil
        } catch let error as KafkaError {
            guard case .partitionsRejected(_, _, _, let code) = error else {
                Issue.record("expected partitionsRejected, got \(error)")
                return nil
            }
            return code
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// Only one of several partitions' codes can be reported. Picking the numerically smallest
    /// let OFFSET_OUT_OF_RANGE (1) mask TOPIC_AUTHORIZATION_FAILED (29), which is the one the
    /// user has to act on.
    @Test("A permission failure is named ahead of anything else")
    func aPermissionFailureIsNamedFirst() {
        #expect(rejectionCode([
            0: .rejected(code: KafkaErrorCode.offsetOutOfRange),
            1: .rejected(code: KafkaErrorCode.topicAuthorizationFailed)
        ]) == KafkaErrorCode.topicAuthorizationFailed)

        #expect(rejectionCode([
            0: .rejected(code: KafkaErrorCode.notLeaderOrFollower),
            5: .rejected(code: KafkaErrorCode.groupAuthorizationFailed)
        ]) == KafkaErrorCode.groupAuthorizationFailed)
    }

    @Test("A real answer is named ahead of a code that only says the cluster is moving")
    func aRealAnswerOutranksATransientOne() {
        #expect(rejectionCode([
            0: .rejected(code: KafkaErrorCode.leaderNotAvailable),
            1: .rejected(code: KafkaErrorCode.offsetOutOfRange)
        ]) == KafkaErrorCode.offsetOutOfRange)
    }

    /// Two codes of the same rank tie on the lowest partition, so the message does not change
    /// between runs of the same broken query.
    @Test("Equally useful codes are broken by partition, not by number")
    func equalCodesTieOnTheLowestPartition() {
        #expect(rejectionCode([
            2: .rejected(code: KafkaErrorCode.offsetOutOfRange),
            1: .rejected(code: KafkaErrorCode.messageTooLarge)
        ]) == KafkaErrorCode.messageTooLarge)
    }

    /// Under bootstrap-only routing the same code means something the user can act on, so it is
    /// reported as the setting rather than as Kafka's wording.
    @Test("Bootstrap-only routing names the setting rather than the error code")
    func bootstrapOnlyNamesTheSetting() {
        let outcomes: [Int32: KafkaPartitionOutcome<Int64>] = [
            0: .value(10),
            3: .rejected(code: KafkaErrorCode.notLeaderOrFollower)
        ]
        do {
            _ = try KafkaPartitionOutcome.requireAll(
                outcomes,
                topic: "orders",
                api: "ListOffsets",
                routing: .bootstrapOnly
            )
            Issue.record("expected the partitions led elsewhere to be reported")
        } catch let error as KafkaError {
            guard case .partitionsLedElsewhere(let topic, let partitions) = error else {
                Issue.record("expected partitionsLedElsewhere, got \(error)")
                return
            }
            #expect(topic == "orders")
            #expect(partitions == [3])
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// A partition with no answer used to become earliest 0 / latest 0, which reads as a real
    /// empty partition: the sidebar under-counted and a tail scan restarted from the log's
    /// beginning, with nothing raised.
    @Test("A partition that could not be reached is an error, not a zero")
    func anUnreachablePartitionIsNotZero() {
        let outcomes: [Int32: KafkaPartitionOutcome<Int64>] = [
            0: .value(10),
            1: .failed(.brokerUnreachable(nodeId: 2, address: "kafka-2.internal:9092", reason: "timed out"))
        ]
        #expect(throws: KafkaError.self) {
            _ = try KafkaPartitionOutcome.requireAll(
                outcomes,
                topic: "orders",
                api: "ListOffsets",
                routing: .advertised
            )
        }
    }

    /// Fetch and Produce report a partition's error code by throwing it, so the fan-out has to
    /// record that as a rejection rather than a failure or those two lose their retry.
    @Test("A thrown broker code is recorded as a rejection, so it still retries")
    func aThrownBrokerCodeStaysRetriable() {
        let thrown = KafkaError.broker(code: KafkaErrorCode.notLeaderOrFollower, api: "Fetch")
        guard case .rejected(let code) = KafkaPartitionOutcome<Int64>.outcome(for: thrown) else {
            Issue.record("a thrown broker code must become a rejection")
            return
        }
        #expect(code == KafkaErrorCode.notLeaderOrFollower)
        #expect(KafkaErrorCode.retryAction(for: code) == .resolveLeaderAgain)
    }

    @Test("A transport failure is recorded as a failure, and is not retried as a moved leader")
    func aTransportFailureIsNotARejection() {
        let thrown = KafkaError.brokerUnreachable(nodeId: 2, address: "kafka-2:9092", reason: "timed out")
        guard case .failed = KafkaPartitionOutcome<Int64>.outcome(for: thrown) else {
            Issue.record("an unreachable broker must not be recorded as a broker rejection")
            return
        }
    }

    // MARK: - Partition filters

    @Test("A partition filter that names every partition is kept")
    func aValidPartitionFilterIsKept() throws {
        let selected = try KafkaBrowseEngine.resolvePartitions([2, 0], available: [0, 1, 2], topic: "orders")
        #expect(selected == [0, 2])
    }

    @Test("No filter reads every partition")
    func noFilterReadsEverything() throws {
        let selected = try KafkaBrowseEngine.resolvePartitions(nil, available: [0, 1, 2], topic: "orders")
        #expect(selected == [0, 1, 2])
    }

    /// Filtering a partition the topic does not have used to return an empty page, which is
    /// exactly what an empty topic returns. The topic name has refused to work that way since
    /// the driver shipped and a partition number is no different.
    @Test("A partition the topic does not have is reported, not dropped")
    func anUnknownPartitionIsReported() {
        #expect(throws: KafkaError.self) {
            _ = try KafkaBrowseEngine.resolvePartitions([0, 99], available: [0, 1, 2], topic: "orders")
        }
    }

    // MARK: - Which end of the window is the page

    private func record(partition: Int32, offset: Int64) -> KafkaRecord {
        KafkaRecord(
            offset: offset,
            timestamp: offset,
            timestampIsLogAppendTime: false,
            key: nil,
            value: nil,
            headers: [],
            partition: partition
        )
    }

    /// The defect that made `FROM NEWEST` a lie on any multi-partition topic. Each partition is
    /// stepped back by the page size and read forward, so the merged run holds several pages and
    /// its newest records are at the end.
    @Test("A tail scan shows the newest records of its window, not the oldest")
    func aTailScanTakesTheTail() {
        let merged = KafkaRecordOrdering.merge((0 ..< 9).map { record(partition: Int32($0 % 3), offset: Int64($0)) })
        let page = KafkaRecordOrdering.page(merged, skip: 0, limit: 3, readsBackward: true)
        #expect(page.map(\.offset) == [6, 7, 8])
    }

    @Test("A forward scan shows the oldest records of its window")
    func aForwardScanTakesTheHead() {
        let merged = KafkaRecordOrdering.merge((0 ..< 9).map { record(partition: Int32($0 % 3), offset: Int64($0)) })
        let page = KafkaRecordOrdering.page(merged, skip: 0, limit: 3, readsBackward: false)
        #expect(page.map(\.offset) == [0, 1, 2])
    }

    /// Page two of a tail scan is the page before page one, so it steps further back from the
    /// same end rather than further forward from the same start.
    @Test("Paging a tail scan walks backwards")
    func pagingATailScanWalksBackwards() {
        let merged = KafkaRecordOrdering.merge((0 ..< 9).map { record(partition: Int32($0 % 3), offset: Int64($0)) })
        #expect(KafkaRecordOrdering.page(merged, skip: 3, limit: 3, readsBackward: true).map(\.offset) == [3, 4, 5])
        #expect(KafkaRecordOrdering.page(merged, skip: 6, limit: 3, readsBackward: true).map(\.offset) == [0, 1, 2])
    }

    @Test("Paging a forward scan walks forwards")
    func pagingAForwardScanWalksForwards() {
        let merged = KafkaRecordOrdering.merge((0 ..< 9).map { record(partition: Int32($0 % 3), offset: Int64($0)) })
        #expect(KafkaRecordOrdering.page(merged, skip: 3, limit: 3, readsBackward: false).map(\.offset) == [3, 4, 5])
        #expect(KafkaRecordOrdering.page(merged, skip: 6, limit: 3, readsBackward: false).map(\.offset) == [6, 7, 8])
    }

    /// With one partition the two directions select the same rows, which is why every existing
    /// assertion passed while the multi-partition case was wrong.
    @Test("One partition cannot tell the two directions apart")
    func onePartitionHidesTheDirection() {
        let merged = KafkaRecordOrdering.merge((0 ..< 5).map { record(partition: 0, offset: Int64($0)) })
        let backward = KafkaRecordOrdering.page(merged, skip: 0, limit: 5, readsBackward: true)
        let forward = KafkaRecordOrdering.page(merged, skip: 0, limit: 5, readsBackward: false)
        #expect(backward.map(\.offset) == forward.map(\.offset))
    }

    @Test("A page bigger than the window is the whole window")
    func aPageBiggerThanTheWindowIsTheWindow() {
        let merged = KafkaRecordOrdering.merge((0 ..< 3).map { record(partition: 0, offset: Int64($0)) })
        #expect(KafkaRecordOrdering.page(merged, skip: 0, limit: 10, readsBackward: true).count == 3)
        #expect(KafkaRecordOrdering.page(merged, skip: 10, limit: 10, readsBackward: true).isEmpty)
    }
}
