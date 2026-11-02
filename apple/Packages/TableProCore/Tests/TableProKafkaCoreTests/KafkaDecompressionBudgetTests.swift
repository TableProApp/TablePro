import Foundation
import TableProKafkaCore
import TableProWireIO
import Testing

private func compressed(_ records: Data, as codec: KafkaCompressionCodec) -> Data {
    let bytes = [UInt8](records)
    switch codec {
    case .none: return records
    case .gzip: return KafkaBatchFixture.gzip(records)
    case .snappy: return KafkaBatchFixture.xerial([KafkaBatchFixture.snappyLiteral(bytes)])
    case .lz4: return KafkaBatchFixture.lz4Frame([(bytes: KafkaBatchFixture.lz4Literal(bytes), compressed: true)])
    case .zstd: return KafkaBatchFixture.zstdRawFrame(bytes)
    }
}

private func smallBudget(limit: Int) -> DecompressionBudget {
    DecompressionBudget(limit: limit, ratioLimit: 250, grace: .max)
}

@Test(arguments: [KafkaCompressionCodec.none, .gzip, .snappy, .lz4, .zstd])
func everyCodecStillDecodesAValidBatch(codec: KafkaCompressionCodec) throws {
    let records = KafkaBatchFixture.record(offsetDelta: 0, value: Data("first".utf8))
        + KafkaBatchFixture.record(offsetDelta: 1, value: Data(String(repeating: "second ", count: 40).utf8))
    let blob = KafkaBatchFixture.batch(baseOffset: 100, codec: codec, recordCount: 2, payload: compressed(records, as: codec))
    var budget = DecompressionBudget.standard
    let decoded = try KafkaRecordBatchDecoder.decode(blob: blob, partition: 3, skipAborted: true, budget: &budget)
    #expect(decoded.records.map { $0.offset } == [100, 101])
    #expect(decoded.records.map { $0.value } == [Data("first".utf8), Data(String(repeating: "second ", count: 40).utf8)])
    #expect(decoded.records.allSatisfy { $0.partition == 3 })
    #expect(!decoded.truncated)
}

@Test func codecsDecodeReferenceFrames() throws {
    var budget = DecompressionBudget.standard
    let declaredZstd: [UInt8] = KafkaBatchFixture.zstdMagic + [0x20, 0x08, 0x28, 0x00, 0x00] + Array("hello".utf8) + [0x1B, 0x00, 0x00, 0x21]
    let fromDeclaredZstd = try KafkaCompression.decompress(Data(declaredZstd), codec: .zstd, budget: &budget)
    #expect(fromDeclaredZstd == Data("hello!!!".utf8))

    let fromStreamedZstd = try KafkaCompression.decompress(KafkaBatchFixture.zstdRunFrame(of: 0x41, blocks: 3), codec: .zstd, budget: &budget)
    #expect(fromStreamedZstd == Data(repeating: 0x41, count: 3 * 128 * 1_024))

    let lz4Match: [UInt8] = [0x3E, 0x61, 0x62, 0x63, 0x03, 0x00, 0x50, 0x31, 0x32, 0x33, 0x34, 0x35]
    let lz4 = KafkaBatchFixture.lz4Frame([(bytes: lz4Match, compressed: true), (bytes: Array("xyz".utf8), compressed: false)])
    let fromLz4 = try KafkaCompression.decompress(lz4, codec: .lz4, budget: &budget)
    #expect(fromLz4 == Data("abcabcabcabcabcabcabc12345xyz".utf8))

    let snappyLiteral: [UInt8] = [0x05, 0x10] + Array("hello".utf8)
    let snappyCopy: [UInt8] = [0x08, 0x04, 0x61, 0x62, 0x09, 0x02]
    let fromSnappy = try KafkaCompression.decompress(KafkaBatchFixture.xerial([snappyLiteral, snappyCopy]), codec: .snappy, budget: &budget)
    #expect(fromSnappy == Data("helloabababab".utf8))
}

@Test func gzipBatchOfZerosIsRefusedPastTheLimit() {
    let record = KafkaBatchFixture.zeroValueRecord(valueLength: 16 << 20)
    let payload = KafkaBatchFixture.gzip(record.head, zeros: 16 << 20, record.tail)
    let blob = KafkaBatchFixture.batch(codec: .gzip, payload: payload)
    var budget = smallBudget(limit: 1 << 20)
    let error = #expect(throws: KafkaError.self) {
        try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true, budget: &budget)
    }
    #expect(refusedCodec(error) == "gzip")
}

// A reply holding one 1 GiB record in about 1 MiB of gzip, under the budget a real fetch asks for.
@Test func gzipBombIsRefusedOnceItOutrunsTheRatio() throws {
    let member = KafkaBatchFixture.gzip(Data(), zeros: 1 << 20)
    let payload = Data((0 ..< 1_024).flatMap { _ in member })
    let blob = KafkaBatchFixture.batch(codec: .gzip, payload: payload)
    var budget = try KafkaCompression.fetchBudget(requesting: 1 << 20)
    let error = #expect(throws: KafkaError.self) {
        try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true, budget: &budget)
    }
    #expect(refusedCodec(error) == "gzip")
}

@Test func runningTotalRefusesBatchesThatFitOneAtATime() throws {
    let record = KafkaBatchFixture.zeroValueRecord(valueLength: 1 << 20)
    let payload = KafkaBatchFixture.gzip(record.head, zeros: 1 << 20, record.tail)
    let one = KafkaBatchFixture.batch(codec: .gzip, payload: payload)

    var roomForTwo = smallBudget(limit: (5 << 20) / 2)
    let two = try KafkaRecordBatchDecoder.decode(blob: one + one, partition: 0, skipAborted: true, budget: &roomForTwo)
    #expect(two.records.map { $0.value?.count } == [1 << 20, 1 << 20])

    var budget = smallBudget(limit: (5 << 20) / 2)
    let error = #expect(throws: KafkaError.self) {
        try KafkaRecordBatchDecoder.decode(blob: one + one + one, partition: 0, skipAborted: true, budget: &budget)
    }
    #expect(refusedCodec(error) == "gzip")
}

@Test func zstdFrameWithoutDeclaredSizeIsBounded() {
    var budget = smallBudget(limit: 1 << 20)
    let error = #expect(throws: KafkaError.self) {
        try KafkaCompression.decompress(KafkaBatchFixture.zstdRunFrame(of: 0, blocks: 64), codec: .zstd, budget: &budget)
    }
    #expect(refusedCodec(error) == "zstd")
}

@Test func zstdFrameThatStopsEarlyIsAnError() {
    var budget = DecompressionBudget.standard
    let frame = KafkaBatchFixture.zstdRunFrame(of: 0x41, blocks: 3).dropLast()
    let error = #expect(throws: KafkaError.self) {
        try KafkaCompression.decompress(Data(frame), codec: .zstd, budget: &budget)
    }
    guard case .decompressionFailed(let codec, _)? = error else {
        Issue.record("expected a decompression failure, got \(String(describing: error))")
        return
    }
    #expect(codec == "zstd")
}

// Each block repeats one byte to 64 KiB from a few hundred bytes; only the total across blocks is bounded.
@Test func snappyAndLz4BlocksAreBoundedAcrossTheFrame() {
    let snappyBlock: [UInt8] = KafkaBatchFixture.varint(1 + 64 * 1_024) + [0x00, 0x61]
        + Array([[UInt8]](repeating: [0xFE, 0x01, 0x00], count: 1_024).joined())
    var snappyBudget = smallBudget(limit: 200_000)
    let snappyError = #expect(throws: KafkaError.self) {
        try KafkaCompression.decompress(
            KafkaBatchFixture.xerial(Array(repeating: snappyBlock, count: 8)),
            codec: .snappy,
            budget: &snappyBudget
        )
    }
    #expect(refusedCodec(snappyError) == "snappy")

    let lz4Block: [UInt8] = [0x1F, 0x61, 0x01, 0x00] + [UInt8](repeating: 0xFF, count: 256) + [231, 0x50]
        + Array("aaaaa".utf8)
    var lz4Budget = smallBudget(limit: 200_000)
    let lz4Error = #expect(throws: KafkaError.self) {
        try KafkaCompression.decompress(
            KafkaBatchFixture.lz4Frame(Array(repeating: (bytes: lz4Block, compressed: true), count: 8)),
            codec: .lz4,
            budget: &lz4Budget
        )
    }
    #expect(refusedCodec(lz4Error) == "lz4")
}

// Written by `lz4 -9 -BX --content-size`: a content size, block checksums and a content checksum.
@Test func lz4DecodesAFrameFromTheLz4Tool() throws {
    let frame: [UInt8] = [
        0x04, 0x22, 0x4D, 0x18, 0x7C, 0x40, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xCF, 0x26, 0x00, 0x00, 0x00, 0xF3, 0x02, 0x69, 0x64, 0x2C,
        0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x31, 0x2C, 0x6B, 0x61, 0x66, 0x6B, 0x61,
        0x0A, 0x32, 0x08, 0x00, 0x13, 0x33, 0x08, 0x00, 0x13, 0x34, 0x08, 0x00,
        0x80, 0x35, 0x2C, 0x6B, 0x61, 0x66, 0x6B, 0x61, 0x0A, 0xB6, 0x36, 0x44,
        0xC3, 0x00, 0x00, 0x00, 0x00, 0x41, 0x82, 0x17, 0x17
    ]
    var budget = DecompressionBudget.standard
    let decoded = try KafkaCompression.decompress(Data(frame), codec: .lz4, budget: &budget)
    #expect(decoded == Data("id,name\n1,kafka\n2,kafka\n3,kafka\n4,kafka\n5,kafka\n".utf8))
}

// The second block decodes into the buffer the first one filled, so only its own bytes may follow.
@Test func lz4BlocksOfOneFrameKeepToTheirOwnBytes() throws {
    let fill: [UInt8] = [0x1F, 0x61, 0x01, 0x00] + [UInt8](repeating: 0xFF, count: 256) + [231, 0x50]
        + Array("aaaaa".utf8)
    let frame = KafkaBatchFixture.lz4Frame([
        (bytes: fill, compressed: true),
        (bytes: KafkaBatchFixture.lz4Literal(Array("xyz".utf8)), compressed: true)
    ])
    var budget = DecompressionBudget.standard
    let decoded = try KafkaCompression.decompress(frame, codec: .lz4, budget: &budget)
    #expect(decoded == Data(repeating: 0x61, count: 64 * 1_024) + Data("xyz".utf8))
}

// 4 Mi one-byte blocks in a frame that declares 4 MiB blocks: a 4 MiB zero fill per block runs
// far past the time limit.
@Test(.timeLimit(.minutes(1)))
func lz4FrameOfTinyBlocksCostsWhatItHolds() throws {
    let count = 1 << 22
    var budget = DecompressionBudget.standard
    let decoded = try KafkaCompression.decompress(
        KafkaBatchFixture.lz4FrameOfOneByteBlocks(0x41, count: count),
        codec: .lz4,
        budget: &budget
    )
    #expect(decoded == Data(repeating: 0x41, count: count))
}

@Test func fetchBudgetCarriesItsTotalsAcrossPages() throws {
    let first = try KafkaCompression.fetchBudget(requesting: 1 << 20)
    #expect(first.limit == 250 << 20)
    #expect(first.ratioLimit == DecompressionBudget.standard.ratioLimit)
    #expect(first.grace == DecompressionBudget.standard.grace)

    var spent = first
    try spent.record(produced: 10 << 20, consumed: 1 << 20)
    let next = try KafkaCompression.fetchBudget(requesting: 4 << 20, after: spent)
    #expect(next.produced == 10 << 20)
    #expect(next.consumed == 1 << 20)
    #expect(next.limit == (10 << 20) + (1_000 << 20))
}

// Escalated to a 64 MiB request, the standard ratio alone would let one read hold 16 GiB.
@Test func fetchBudgetGivesEachPageAtMostOneGibibyte() throws {
    #expect(try KafkaCompression.fetchBudget(requesting: 64 << 20).limit == 1 << 30)
    #expect(try KafkaCompression.fetchBudget(requesting: .max).limit == 1 << 30)

    // A long read of large records keeps paging past the ceiling, one page's allowance at a time.
    var spent = DecompressionBudget(ratioLimit: DecompressionBudget.standard.ratioLimit, grace: DecompressionBudget.standard.grace)
    try spent.record(produced: 1_100 << 20, consumed: 40 << 20)
    #expect(try KafkaCompression.fetchBudget(requesting: 1 << 20, after: spent).limit == (1_100 + 250) << 20)
    #expect(try KafkaCompression.fetchBudget(requesting: 64 << 20, after: spent).limit == (1_100 << 20) + (1 << 30))
}
