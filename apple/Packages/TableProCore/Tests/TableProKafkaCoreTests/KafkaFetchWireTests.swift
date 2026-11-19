import Foundation
import TableProKafkaCore
import Testing

private let oneMebibyte: Int32 = 1_024 * 1_024

private func request(version: Int16, flexible: Bool, targets: [KafkaFetchTarget], responseBytes: Int32) -> [UInt8] {
    var writer = KafkaProtocolWriter()
    KafkaFetchWire.writeRequest(
        into: &writer,
        version: version,
        flexible: flexible,
        topic: "orders",
        targets: targets,
        partitionBytes: oneMebibyte,
        responseBytes: responseBytes
    )
    return writer.bytes
}

private let twoPartitions = [
    KafkaFetchTarget(partition: 0, startOffset: 10),
    KafkaFetchTarget(partition: 3, startOffset: 20),
]

struct KafkaFetchWireRequestTests {
    @Test("v4 names every partition of the topic in one request")
    func legacyRequest() {
        var expected = KafkaProtocolWriter()
        expected.int32(-1)
        expected.int32(500)
        expected.int32(1)
        expected.int32(2 * oneMebibyte)
        expected.int8(1)
        expected.legacyArrayCount(1)
        expected.legacyString("orders")
        expected.legacyArrayCount(2)
        for (partition, offset) in [(Int32(0), Int64(10)), (3, 20)] {
            expected.int32(partition)
            expected.int64(offset)
            expected.int32(oneMebibyte)
        }
        #expect(request(version: 4, flexible: false, targets: twoPartitions, responseBytes: 2 * oneMebibyte) == expected.bytes)
    }

    @Test("v11 carries the session, the leader epoch, the log start and the rack")
    func sessionRequest() {
        var expected = KafkaProtocolWriter()
        expected.int32(-1)
        expected.int32(500)
        expected.int32(1)
        expected.int32(2 * oneMebibyte)
        expected.int8(1)
        expected.int32(0)
        expected.int32(0)
        expected.legacyArrayCount(1)
        expected.legacyString("orders")
        expected.legacyArrayCount(2)
        for (partition, offset) in [(Int32(0), Int64(10)), (3, 20)] {
            expected.int32(partition)
            expected.int32(-1)
            expected.int64(offset)
            expected.int64(-1)
            expected.int32(oneMebibyte)
        }
        expected.legacyArrayCount(0)
        expected.legacyString("")
        #expect(request(version: 11, flexible: false, targets: twoPartitions, responseBytes: 2 * oneMebibyte) == expected.bytes)
    }

    @Test("v12 is compact and closes each partition, the topic and the body with tagged fields")
    func flexibleRequest() {
        var expected = KafkaProtocolWriter()
        expected.int32(-1)
        expected.int32(500)
        expected.int32(1)
        expected.int32(2 * oneMebibyte)
        expected.int8(1)
        expected.int32(0)
        expected.int32(0)
        expected.compactArrayCount(1)
        expected.compactString("orders")
        expected.compactArrayCount(2)
        for (partition, offset) in [(Int32(0), Int64(10)), (3, 20)] {
            expected.int32(partition)
            expected.int32(-1)
            expected.int64(offset)
            expected.int32(-1)
            expected.int64(-1)
            expected.int32(oneMebibyte)
            expected.emptyTaggedFields()
        }
        expected.emptyTaggedFields()
        expected.compactArrayCount(0)
        expected.compactString("")
        expected.emptyTaggedFields()
        #expect(request(version: 12, flexible: true, targets: twoPartitions, responseBytes: 2 * oneMebibyte) == expected.bytes)
    }

    @Test("One partition asks for as many bytes in the response as in the partition")
    func singlePartitionKeepsItsBudget() {
        #expect(KafkaFetchWire.responseBytes(partitions: 1, partitionBytes: oneMebibyte) == oneMebibyte)
        #expect(KafkaFetchWire.responseBytes(partitions: 1, partitionBytes: 64 * oneMebibyte) == 64 * oneMebibyte)
    }

    @Test("The response limit grows with the partitions a request names")
    func responseLimitGrows() {
        #expect(KafkaFetchWire.responseBytes(partitions: 12, partitionBytes: oneMebibyte) == 12 * oneMebibyte)
    }

    @Test("A partition count that overflows the product still gives a limit")
    func overflowingProductIsClamped() {
        #expect(KafkaFetchWire.responseBytes(partitions: .max, partitionBytes: oneMebibyte) == .max)
    }

    @Test("A reply may pass its record bytes by a quarter for the fields around them")
    func replyAllowance() {
        #expect(KafkaFetchWire.replyBytes(partitionBytes: oneMebibyte) == 1_310_720)
    }
}

struct KafkaFetchWireFirstReadsTests {
    @Test("A forward scan reads every partition together, lowest first")
    func forwardScan() {
        let reads = KafkaFetchWire.firstReads(start: [2: 5, 0: 7], tail: [:], wanted: 100, partitionBytes: oneMebibyte)
        #expect(reads == [
            KafkaFetchTarget(partition: 0, startOffset: 7),
            KafkaFetchTarget(partition: 2, startOffset: 5),
        ])
    }

    @Test("A tail window that holds nothing is left out")
    func emptyTailWindowIsLeftOut() {
        let reads = KafkaFetchWire.firstReads(
            start: [0: 5, 1: 9, 2: 3], tail: [0: 10, 1: 9, 2: 8], wanted: 100, partitionBytes: oneMebibyte
        )
        #expect(reads.map(\.partition) == [0, 2])
    }

    @Test("A browse of thousands of partitions reads together only the lowest ones the byte budget holds")
    func firstReadsFitTheBudget() {
        let start = Dictionary(uniqueKeysWithValues: (0 ..< 5_000).map { (Int32($0), Int64(0)) })
        let reads = KafkaFetchWire.firstReads(start: start, tail: [:], wanted: 1, partitionBytes: oneMebibyte)

        #expect(reads.map(\.partition) == Array(0 ..< 51))
        #expect(reads.count * KafkaFetchWire.replyBytes(partitionBytes: oneMebibyte) <= KafkaFetchWire.firstPagesByteBudget)
    }

    @Test("One partition has nothing to share a request with")
    func onePartitionIsReadAsBefore() {
        #expect(KafkaFetchWire.firstReads(start: [0: 5], tail: [:], wanted: 100, partitionBytes: oneMebibyte).isEmpty)
    }

    @Test("A page of no rows reads nothing")
    func noRowsWanted() {
        #expect(KafkaFetchWire.firstReads(start: [0: 5, 1: 6], tail: [:], wanted: 0, partitionBytes: oneMebibyte).isEmpty)
    }
}

struct KafkaFetchByteBudgetTests {
    @Test("A request takes as many partitions as the budget has room for")
    func reservesWhatFits() {
        let budget = KafkaFetchByteBudget(limit: 10)

        #expect(budget.reserve(partitions: 4, bytesEach: 3) == 3)
        #expect(budget.remaining == 1)
    }

    @Test("Leaders share one budget, so a later request gets only what is left")
    func leadersShareTheBudget() {
        let budget = KafkaFetchByteBudget(limit: 10)

        #expect(budget.reserve(partitions: 2, bytesEach: 3) == 2)
        #expect(budget.reserve(partitions: 2, bytesEach: 3) == 1)
        #expect(budget.reserve(partitions: 2, bytesEach: 3) == 0)
        #expect(budget.remaining == 1)
    }

    @Test("A request that does not fit reserves nothing")
    func nothingFits() {
        let budget = KafkaFetchByteBudget(limit: 2)

        #expect(budget.reserve(partitions: 1, bytesEach: 3) == 0)
        #expect(budget.remaining == 2)
    }

    @Test("Requests from every leader at once never reserve past the limit")
    func concurrentReservationsStayBounded() async {
        let budget = KafkaFetchByteBudget(limit: 64 * 1_310_720)
        let granted = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 200 {
                group.addTask { budget.reserve(partitions: 3, bytesEach: 1_310_720) }
            }
            return await group.reduce(0, +)
        }

        #expect(granted == 64)
        #expect(budget.remaining == 0)
    }
}

struct KafkaFetchWireResponseTests {
    private func legacyResponse() -> KafkaProtocolReader {
        var writer = KafkaProtocolWriter()
        writer.int32(0)                                       // throttleTimeMs
        writer.int16(0)                                       // errorCode
        writer.int32(0)                                       // sessionId
        writer.legacyArrayCount(1)
        writer.legacyString("orders")
        writer.legacyArrayCount(3)

        writer.int32(0)
        writer.int16(0)
        writer.int64(40)
        writer.int64(40)
        writer.int64(0)
        writer.legacyArrayCount(1)
        writer.int64(77)
        writer.int64(12)
        writer.nullableLegacyBytes(Data([1, 2, 3]))

        writer.int32(1)
        writer.int16(KafkaErrorCode.notLeaderOrFollower)
        writer.int64(-1)
        writer.int64(-1)
        writer.int64(-1)
        writer.legacyArrayCount(0)
        writer.nullableLegacyBytes(nil)

        writer.int32(2)
        writer.int16(0)
        writer.int64(9)
        writer.int64(9)
        writer.int64(0)
        writer.legacyArrayCount(nil)
        writer.nullableLegacyBytes(Data())
        return KafkaProtocolReader(writer.bytes)
    }

    @Test("Each partition of a reply keeps its own answer")
    func partitionsKeepTheirOwnAnswers() throws {
        var body = legacyResponse()
        let partitions = try KafkaFetchWire.readResponse(&body, version: 7, flexible: false)

        #expect(partitions.map(\.partition) == [0, 1, 2])
        #expect(partitions[0].errorCode == KafkaErrorCode.none)
        #expect(partitions[0].highWatermark == 40)
        #expect(partitions[0].abortedTransactions.map(\.producerId) == [77])
        #expect(partitions[0].recordBatches == Data([1, 2, 3]))
        #expect(partitions[1].errorCode == KafkaErrorCode.notLeaderOrFollower)
        #expect(partitions[1].recordBatches == nil)
        #expect(partitions[2].highWatermark == 9)
        #expect(partitions[2].recordBatches?.isEmpty == true)
        #expect(body.isAtEnd)
    }

    @Test("An error for the whole request throws")
    func requestErrorThrows() {
        var writer = KafkaProtocolWriter()
        writer.int32(0)
        writer.int16(KafkaErrorCode.topicAuthorizationFailed)
        writer.int32(0)
        writer.legacyArrayCount(0)
        var body = KafkaProtocolReader(writer.bytes)
        #expect(throws: KafkaError.self) {
            _ = try KafkaFetchWire.readResponse(&body, version: 7, flexible: false)
        }
    }

    @Test("v4 has no request error, session or log start offset")
    func oldestVersion() throws {
        var writer = KafkaProtocolWriter()
        writer.int32(0)
        writer.legacyArrayCount(1)
        writer.legacyString("orders")
        writer.legacyArrayCount(1)
        writer.int32(4)
        writer.int16(0)
        writer.int64(15)
        writer.int64(15)
        writer.legacyArrayCount(0)
        writer.nullableLegacyBytes(Data([9]))
        var body = KafkaProtocolReader(writer.bytes)

        let partitions = try KafkaFetchWire.readResponse(&body, version: 4, flexible: false)

        #expect(partitions.map(\.partition) == [4])
        #expect(partitions.first?.recordBatches == Data([9]))
        #expect(body.isAtEnd)
    }

    @Test("v12 reads compact arrays, the read replica and tagged fields")
    func flexibleResponse() throws {
        var writer = KafkaProtocolWriter()
        writer.int32(0)
        writer.int16(0)
        writer.int32(0)
        writer.compactArrayCount(1)
        writer.compactString("orders")
        writer.compactArrayCount(2)
        for (partition, batch) in [(Int32(0), Data([5])), (1, Data([6, 7]))] {
            writer.int32(partition)
            writer.int16(0)
            writer.int64(30)
            writer.int64(30)
            writer.int64(0)
            writer.compactArrayCount(1)
            writer.int64(8)
            writer.int64(2)
            writer.emptyTaggedFields()
            writer.int32(-1)
            writer.nullableCompactBytes(batch)
            writer.emptyTaggedFields()
        }
        writer.emptyTaggedFields()
        writer.emptyTaggedFields()
        var body = KafkaProtocolReader(writer.bytes)

        let partitions = try KafkaFetchWire.readResponse(&body, version: 12, flexible: true)

        #expect(partitions.map(\.recordBatches) == [Data([5]), Data([6, 7])])
        #expect(partitions.map { $0.abortedTransactions.count } == [1, 1])
    }
}
