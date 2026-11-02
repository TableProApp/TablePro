import Compression
import Foundation
import libzstd
import TableProGzip
import TableProWireIO

/// A Kafka broker never transcodes a batch for the consumer: it hands back exactly the bytes
/// the producer stored, in whatever codec the producer chose. Measured against a live broker
/// by producing one topic per codec and reading the stored attribute plus the payload's magic
/// bytes back: gzip `1f8b0800`, snappy `82 53 4e 41 50 50 59 00` (xerial framing, not raw
/// snappy), lz4 `04224d18` (the LZ4 frame format, not a raw block), zstd `28b52ffd`.
///
/// So all four have to be decoded here. macOS supplies only some of that: zlib is in the SDK,
/// Compression.framework has a raw LZ4 block decoder, and there is no snappy and no zstd
/// anywhere on the system (verified by reading compression.h and by dlopen'ing libarchive,
/// which exports no ZSTD_ symbol). zstd therefore comes from the upstream SPM package and
/// snappy is implemented here.
public enum KafkaCompression {
    // Every codec charges `budget` as its output grows, so no declared or undeclared size gets
    // past it, and one budget spans every batch of a fetch.
    public static func decompress(
        _ payload: Data,
        codec: KafkaCompressionCodec,
        budget: inout DecompressionBudget
    ) throws -> Data {
        switch codec {
        case .none: return payload
        case .gzip: return try gunzip(payload, budget: &budget)
        case .snappy: return try snappyXerial(payload, budget: &budget)
        case .lz4: return try lz4Frame(payload, budget: &budget)
        case .zstd: return try zstd(payload, budget: &budget)
        }
    }

    // The standard ratio on a 64 MiB request would let one reply expand to 16 GiB.
    static let fetchOutputCeiling = 1 << 30

    // A Fetch reply may expand to what its byte limit could hold at the standard ratio, up to the
    // ceiling. The totals carry over from the earlier pages of the same read, so paging never
    // resets the grace, while each page gets its own allowance.
    public static func fetchBudget(
        requesting requestedBytes: Int32,
        after spent: DecompressionBudget? = nil
    ) throws(WireIOError) -> DecompressionBudget {
        let standard = DecompressionBudget.standard
        let (allowance, allowanceOverflows) = Int(max(requestedBytes, 0))
            .multipliedReportingOverflow(by: standard.ratioLimit)
        let pageAllowance = allowanceOverflows ? fetchOutputCeiling : min(allowance, fetchOutputCeiling)
        let (limit, limitOverflows) = (spent?.produced ?? 0).addingReportingOverflow(pageAllowance)
        var budget = DecompressionBudget(
            limit: limitOverflows ? .max : max(limit, standard.grace),
            ratioLimit: standard.ratioLimit,
            grace: standard.grace
        )
        if let spent {
            try budget.record(produced: spent.produced, consumed: spent.consumed)
        }
        return budget
    }

    static func charge(
        _ budget: inout DecompressionBudget,
        produced: Int,
        consumed: Int,
        codec: KafkaCompressionCodec
    ) throws {
        do {
            try budget.record(produced: produced, consumed: consumed)
        } catch {
            throw KafkaError.decompressionExceeded(codec: codec.name)
        }
    }

    // MARK: - gzip

    private static func gunzip(_ payload: Data, budget: inout DecompressionBudget) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        let output: Data
        do {
            output = try GzipInflater.decompress(payload, budget: budget)
        } catch GzipError.expandsTooFar {
            throw KafkaError.decompressionExceeded(codec: "gzip")
        } catch {
            throw KafkaError.decompressionFailed(
                codec: "gzip",
                reason: String(localized: "the compressed data is corrupt or was cut short")
            )
        }
        // The inflater checked a copy that started from these totals, so this carries them forward.
        try charge(&budget, produced: output.count, consumed: payload.count, codec: .gzip)
        return output
    }

    // MARK: - snappy

    private static let xerialMagic: [UInt8] = [0x82, 0x53, 0x4E, 0x41, 0x50, 0x50, 0x59, 0x00]

    // The Java producer frames snappy as xerial: the magic, two version ints, then big-endian
    // length-prefixed blocks. Some non-Java clients write one bare block instead.
    private static func snappyXerial(_ payload: Data, budget: inout DecompressionBudget) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes.count >= xerialMagic.count, Array(bytes.prefix(8)) == xerialMagic else {
            return Data(try SnappyDecoder.decode(bytes, budget: &budget))
        }
        var cursor = 16                                       // magic + version + compatibleVersion
        var output = Data()
        while cursor + 4 <= bytes.count {
            let length = Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16
                | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            cursor += 4
            guard length >= 0, cursor + length <= bytes.count else {
                throw KafkaError.decompressionFailed(codec: "snappy", reason: "block runs past the payload")
            }
            output.append(contentsOf: try SnappyDecoder.decode(Array(bytes[cursor ..< cursor + length]), budget: &budget))
            cursor += length
        }
        return output
    }

    // MARK: - lz4

    // Kafka writes the LZ4 frame format. COMPRESSION_LZ4 is Apple's own `bv41` container and
    // decodes it to garbage, but the raw blocks inside the frame are COMPRESSION_LZ4_RAW.
    private static func lz4Frame(_ payload: Data, budget: inout DecompressionBudget) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes.count > 7,
              bytes[0] == 0x04, bytes[1] == 0x22, bytes[2] == 0x4D, bytes[3] == 0x18 else {
            throw KafkaError.decompressionFailed(codec: "lz4", reason: "not an LZ4 frame")
        }
        let flags = bytes[4]
        let blockDescriptor = bytes[5]
        let hasContentSize = flags & 0x08 != 0
        let hasDictionaryId = flags & 0x01 != 0
        let hasBlockChecksum = flags & 0x10 != 0
        let maxBlockSize = lz4MaxBlockSize(blockDescriptor)

        var cursor = 7                                        // magic + FLG + BD + header checksum
        if hasContentSize { cursor += 8 }
        if hasDictionaryId { cursor += 4 }

        // One buffer for every block of the frame, left uninitialized, so a block costs what it
        // decodes. Sized by the frame's declared maximum block size, not LZ4's 255x worst case.
        var scratch = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: maxBlockSize)
        defer { scratch.deallocate() }

        var output = Data()
        while cursor + 4 <= bytes.count {
            let rawSize = UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8
                | UInt32(bytes[cursor + 2]) << 16 | UInt32(bytes[cursor + 3]) << 24
            cursor += 4
            if rawSize == 0 { break }                         // EndMark
            let isUncompressed = rawSize & 0x8000_0000 != 0
            let blockSize = Int(rawSize & 0x7FFF_FFFF)
            guard blockSize >= 0, cursor + blockSize <= bytes.count else {
                throw KafkaError.decompressionFailed(codec: "lz4", reason: "block runs past the frame")
            }
            let block = bytes[cursor ..< cursor + blockSize]
            cursor += blockSize
            if hasBlockChecksum { cursor += 4 }

            if isUncompressed {
                try charge(&budget, produced: blockSize, consumed: blockSize + 4, codec: .lz4)
                output.append(contentsOf: block)
                continue
            }
            let capacity = max(maxBlockSize, blockSize + 64)
            if scratch.count < capacity {
                scratch.deallocate()
                scratch = .allocate(capacity: capacity)
            }
            let produced = try lz4RawBlock(block, into: UnsafeMutableBufferPointer(rebasing: scratch[..<capacity]))
            try charge(&budget, produced: produced, consumed: blockSize + 4, codec: .lz4)
            output.append(UnsafeBufferPointer(rebasing: scratch[..<produced]))
        }
        return output
    }

    private static func lz4MaxBlockSize(_ descriptor: UInt8) -> Int {
        switch (descriptor >> 4) & 0x07 {
        case 4: return 64 * 1_024
        case 5: return 256 * 1_024
        case 6: return 1_024 * 1_024
        case 7: return 4 * 1_024 * 1_024
        default: return 4 * 1_024 * 1_024
        }
    }

    private static func lz4RawBlock(
        _ block: ArraySlice<UInt8>,
        into destination: UnsafeMutableBufferPointer<UInt8>
    ) throws -> Int {
        let produced = block.withUnsafeBufferPointer { source -> Int in
            guard let sourceBase = source.baseAddress, let targetBase = destination.baseAddress else { return 0 }
            return compression_decode_buffer(
                targetBase, destination.count,
                sourceBase, source.count,
                nil, COMPRESSION_LZ4_RAW
            )
        }
        guard produced > 0 else {
            throw KafkaError.decompressionFailed(codec: "lz4", reason: "the block did not decode")
        }
        return produced
    }

    // MARK: - zstd

    // Streaming in fixed chunks sizes nothing by the frame's declared size, and handles a frame
    // that declares none the same way.
    private static func zstd(_ payload: Data, budget: inout DecompressionBudget) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        let bytes = [UInt8](payload)
        let declared = bytes.withUnsafeBufferPointer { buffer -> UInt64 in
            guard let base = buffer.baseAddress else { return 0 }
            return ZSTD_getFrameContentSize(base, buffer.count)
        }
        guard declared != UInt64(bitPattern: -2) else {
            throw KafkaError.decompressionFailed(codec: "zstd", reason: "not a zstd frame")
        }
        guard let context = ZSTD_createDCtx() else {
            throw KafkaError.decompressionFailed(codec: "zstd", reason: "could not start zstd")
        }
        defer { ZSTD_freeDCtx(context) }

        var chunk = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var output = Data()
        try bytes.withUnsafeBufferPointer { source in
            var input = ZSTD_inBuffer(src: UnsafeRawPointer(source.baseAddress), size: source.count, pos: 0)
            var frameRemainder = 0
            while input.pos < input.size {
                let consumedBefore = input.pos
                let (result, produced) = chunk.withUnsafeMutableBytes { target -> (Int, Int) in
                    var out = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                    let code = ZSTD_decompressStream(context, &out, &input)
                    return (code, out.pos)
                }
                guard ZSTD_isError(result) == 0 else {
                    throw KafkaError.decompressionFailed(codec: "zstd", reason: zstdMessage(result))
                }
                let consumed = input.pos - consumedBefore
                guard consumed > 0 || produced > 0 else {
                    throw KafkaError.decompressionFailed(codec: "zstd", reason: "the frame stopped decoding")
                }
                try charge(&budget, produced: produced, consumed: consumed, codec: .zstd)
                output.append(contentsOf: chunk[0 ..< produced])
                frameRemainder = result
            }
            // zstd keeps a frame's last input byte until the frame is flushed, so a nonzero
            // remainder once the input is used up means the frame was cut short.
            guard frameRemainder == 0 else {
                throw KafkaError.decompressionFailed(codec: "zstd", reason: "the frame was cut short")
            }
        }
        return output
    }

    private static func zstdMessage(_ code: Int) -> String {
        guard let raw = ZSTD_getErrorName(code) else { return "unknown zstd error" }
        return String(cString: raw)
    }
}
