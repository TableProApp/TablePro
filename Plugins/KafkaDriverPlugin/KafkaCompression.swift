import Compression
import Foundation
import libzstd
import zlib

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
enum KafkaCompression {
    /// The ceiling on what any codec may claim it decompresses to. A declared size is written
    /// by the producer and arrives over the network, so it is a claim rather than a fact.
    static let maximumDecompressedSize = 512 * 1024 * 1024

    static func decompress(_ payload: Data, codec: KafkaCompressionCodec) throws -> Data {
        switch codec {
        case .none: return payload
        case .gzip: return try gunzip(payload)
        case .snappy: return try snappyXerial(payload)
        case .lz4: return try lz4Frame(payload)
        case .zstd: return try zstd(payload)
        }
    }

    // MARK: - gzip

    /// zlib's own gzip mode, selected by adding 16 to the window bits. Compression.framework's
    /// COMPRESSION_ZLIB is raw DEFLATE with no gzip wrapper, so it cannot read this directly.
    private static func gunzip(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw KafkaError.decompressionFailed(codec: "gzip", reason: "could not start zlib")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var input = [UInt8](payload)
        let chunkSize = max(payload.count * 4, 64 * 1024)
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        let status: Int32 = input.withUnsafeMutableBufferPointer { inputBuffer -> Int32 in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)
            while true {
                let result: Int32 = chunk.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    let code = inflate(&stream, Z_NO_FLUSH)
                    let produced = outputBuffer.count - Int(stream.avail_out)
                    if produced > 0 {
                        output.append(contentsOf: outputBuffer.prefix(produced))
                    }
                    return code
                }
                if result == Z_STREAM_END { return Z_STREAM_END }
                if result != Z_OK { return result }
                // Only Z_STREAM_END means the stream ended. Running out of input without it
                // means the payload is truncated, and returning what decoded so far would
                // hand back a partial message that looks like a whole one.
                if stream.avail_in == 0, stream.avail_out != 0 { return Z_DATA_ERROR }
            }
        }

        guard status == Z_STREAM_END else {
            throw KafkaError.decompressionFailed(
                codec: "gzip",
                reason: status == Z_DATA_ERROR
                    ? String(localized: "the compressed data is corrupt or was cut short")
                    : "zlib error \(status)"
            )
        }
        return output
    }

    // MARK: - snappy

    private static let xerialMagic: [UInt8] = [0x82, 0x53, 0x4E, 0x41, 0x50, 0x50, 0x59, 0x00]

    /// The Java producer wraps snappy in "xerial" framing: an 8-byte magic, two version ints,
    /// then a run of big-endian length-prefixed snappy blocks. A payload without the magic is
    /// a single bare snappy block, which is what some non-Java clients write.
    private static func snappyXerial(_ payload: Data) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes.count >= xerialMagic.count, Array(bytes.prefix(8)) == xerialMagic else {
            return Data(try SnappyDecoder.decode(bytes))
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
            output.append(contentsOf: try SnappyDecoder.decode(Array(bytes[cursor ..< cursor + length])))
            cursor += length
        }
        return output
    }

    // MARK: - lz4

    /// Kafka uses the LZ4 FRAME format. Compression.framework's COMPRESSION_LZ4 is Apple's own
    /// container with a `bv41` magic and is not interchangeable with it; reaching for that
    /// instead of parsing the frame yields corrupt output rather than an error. The blocks
    /// inside the frame are raw LZ4, which COMPRESSION_LZ4_RAW does decode.
    private static func lz4Frame(_ payload: Data) throws -> Data {
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
            let block = Array(bytes[cursor ..< cursor + blockSize])
            cursor += blockSize
            if hasBlockChecksum { cursor += 4 }

            if isUncompressed {
                output.append(contentsOf: block)
            } else {
                output.append(contentsOf: try lz4RawBlock(block, capacity: maxBlockSize))
            }
        }
        return output
    }

    private static func lz4MaxBlockSize(_ descriptor: UInt8) -> Int {
        switch (descriptor >> 4) & 0x07 {
        case 4: return 64 * 1024
        case 5: return 256 * 1024
        case 6: return 1024 * 1024
        case 7: return 4 * 1024 * 1024
        default: return 4 * 1024 * 1024
        }
    }

    /// `capacity` is the frame's declared maximum block size, which is the real bound. Sizing
    /// to LZ4's 255x worst case instead means zero-filling 16 MB for every 64 KB block, which
    /// is what the Java producer writes by default.
    private static func lz4RawBlock(_ block: [UInt8], capacity: Int) throws -> [UInt8] {
        var destination = [UInt8](repeating: 0, count: max(capacity, block.count + 64))
        let produced = block.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { target -> Int in
                guard let sourceBase = source.baseAddress, let targetBase = target.baseAddress else { return 0 }
                return compression_decode_buffer(
                    targetBase, target.count,
                    sourceBase, source.count,
                    nil, COMPRESSION_LZ4_RAW
                )
            }
        }
        guard produced > 0 else {
            throw KafkaError.decompressionFailed(codec: "lz4", reason: "the block did not decode")
        }
        return Array(destination.prefix(produced))
    }

    // MARK: - zstd

    private static func zstd(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        let bytes = [UInt8](payload)

        // The frame usually declares its decompressed size. When it does not (a streamed
        // frame writes ZSTD_CONTENTSIZE_UNKNOWN), fall back to a growing buffer.
        let declared = bytes.withUnsafeBufferPointer { buffer -> UInt64 in
            guard let base = buffer.baseAddress else { return 0 }
            return ZSTD_getFrameContentSize(base, buffer.count)
        }
        let unknown = UInt64(bitPattern: -1)
        let error = UInt64(bitPattern: -2)
        guard declared != error else {
            throw KafkaError.decompressionFailed(codec: "zstd", reason: "not a zstd frame")
        }

        // The declared size comes from whoever produced the frame. Snappy caps its own declared
        // length for the same reason: converting an arbitrary UInt64 to Int traps, and honouring
        // one names an allocation nothing here can satisfy.
        guard declared == unknown || declared <= UInt64(maximumDecompressedSize) else {
            throw KafkaError.decompressionFailed(codec: "zstd", reason: "the frame declares an implausible size")
        }
        var capacity = declared == unknown ? max(payload.count * 8, 128 * 1024) : Int(declared)
        for _ in 0 ..< 8 {
            var destination = [UInt8](repeating: 0, count: max(capacity, 1))
            let produced = bytes.withUnsafeBufferPointer { source -> Int in
                destination.withUnsafeMutableBufferPointer { target -> Int in
                    guard let sourceBase = source.baseAddress, let targetBase = target.baseAddress else { return 0 }
                    return ZSTD_decompress(targetBase, target.count, sourceBase, source.count)
                }
            }
            if ZSTD_isError(produced) == 0 {
                return Data(destination.prefix(produced))
            }
            guard declared == unknown else {
                throw KafkaError.decompressionFailed(codec: "zstd", reason: zstdMessage(produced))
            }
            capacity *= 4
        }
        throw KafkaError.decompressionFailed(codec: "zstd", reason: "the frame did not fit a reasonable buffer")
    }

    private static func zstdMessage(_ code: Int) -> String {
        guard let raw = ZSTD_getErrorName(code) else { return "unknown zstd error" }
        return String(cString: raw)
    }
}
