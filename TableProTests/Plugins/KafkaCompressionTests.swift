import Foundation
import libzstd
import Testing

@testable import TablePro

/// A Kafka broker hands back exactly the codec the producer stored and never transcodes, so a
/// gap here is a topic that cannot be read at all. Measured against a live broker: producing
/// one topic per codec and reading the stored batch attribute back gave gzip, snappy, lz4 and
/// zstd unchanged, with xerial framing on snappy and the LZ4 frame format on lz4.
@Suite("Kafka compression")
struct KafkaCompressionTests {
    private static let payload = Data(
        "{\"codec\":\"test\",\"n\":1,\"pad\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}".utf8
    )

    @Test("An uncompressed batch is returned unchanged")
    func noneIsPassthrough() throws {
        #expect(try KafkaCompression.decompress(Self.payload, codec: .none) == Self.payload)
    }

    /// zlib's gzip wrapper, not raw DEFLATE: Compression.framework's COMPRESSION_ZLIB cannot
    /// read this directly, which is why the decoder goes through libz's window-bits mode.
    @Test("A real gzip stream decompresses")
    func gzipRoundTrip() throws {
        let compressed = try Self.gzip(Self.payload)
        #expect(compressed.prefix(3) == Data([0x1F, 0x8B, 0x08]))
        #expect(try KafkaCompression.decompress(compressed, codec: .gzip) == Self.payload)
    }

    @Test("A gzip stream larger than one buffer decompresses whole")
    func gzipLargePayload() throws {
        let large = Data((0 ..< 200_000).map { UInt8($0 % 251) })
        let compressed = try Self.gzip(large)
        #expect(try KafkaCompression.decompress(compressed, codec: .gzip) == large)
    }

    @Test("Corrupt gzip is reported rather than returning partial output")
    func gzipCorruptionIsReported() {
        #expect(throws: KafkaError.self) {
            _ = try KafkaCompression.decompress(Data([0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFF]), codec: .gzip)
        }
    }

    // MARK: - Snappy

    /// Snappy's own format: a varint length, then literals and back-references. macOS ships no
    /// snappy at any layer, so this decoder is the only path for a Java-produced topic.
    @Test("A literal-only snappy block decodes")
    func snappyLiteralBlock() throws {
        let body = Array("hello snappy".utf8)
        var block: [UInt8] = [UInt8(body.count)]           // decompressed length varint
        block.append(UInt8((body.count - 1) << 2))         // literal tag
        block.append(contentsOf: body)
        #expect(try SnappyDecoder.decode(block) == body)
    }

    /// A snappy copy may point into bytes the same loop is still appending, which is how the
    /// format encodes a repeating run. A bulk copy gets this wrong silently.
    @Test("An overlapping snappy copy expands a repeating run")
    func snappyOverlappingCopy() throws {
        // Literal "ab", then a 1-byte-offset copy of length 6 reaching back 2 bytes.
        var block: [UInt8] = [8]                            // 8 bytes out
        block.append(UInt8((2 - 1) << 2))                   // literal, 2 bytes
        block.append(contentsOf: Array("ab".utf8))
        block.append(UInt8(0x01 | ((6 - 4) << 2)))          // copy tag, length 6
        block.append(0x02)                                  // offset 2
        #expect(try SnappyDecoder.decode(block) == Array("abababab".utf8))
    }

    @Test("A snappy block whose declared length disagrees is rejected")
    func snappyLengthMismatchIsRejected() {
        var block: [UInt8] = [99]                           // claims 99 bytes
        block.append(UInt8((2 - 1) << 2))
        block.append(contentsOf: Array("ab".utf8))
        #expect(throws: KafkaError.self) { _ = try SnappyDecoder.decode(block) }
    }

    @Test("A snappy copy reaching before the output start is rejected")
    func snappyBadOffsetIsRejected() {
        var block: [UInt8] = [8]
        block.append(UInt8(0x01))                           // copy before anything was written
        block.append(0x04)
        #expect(throws: KafkaError.self) { _ = try SnappyDecoder.decode(block) }
    }

    /// The Java producer wraps blocks in xerial framing. A payload without the magic is a bare
    /// block, which is what some non-Java clients write.
    @Test("Xerial framing concatenates its blocks in order")
    func snappyXerialFraming() throws {
        func literalBlock(_ text: String) -> [UInt8] {
            let body = Array(text.utf8)
            var block: [UInt8] = [UInt8(body.count)]
            block.append(UInt8((body.count - 1) << 2))
            block.append(contentsOf: body)
            return block
        }

        var framed: [UInt8] = [0x82, 0x53, 0x4E, 0x41, 0x50, 0x50, 0x59, 0x00]
        framed.append(contentsOf: [0x00, 0x00, 0x00, 0x01])   // version
        framed.append(contentsOf: [0x00, 0x00, 0x00, 0x01])   // compatible version
        for text in ["first", "second"] {
            let block = literalBlock(text)
            framed.append(contentsOf: [
                UInt8((block.count >> 24) & 0xFF), UInt8((block.count >> 16) & 0xFF),
                UInt8((block.count >> 8) & 0xFF), UInt8(block.count & 0xFF)
            ])
            framed.append(contentsOf: block)
        }

        let decoded = try KafkaCompression.decompress(Data(framed), codec: .snappy)
        #expect(String(data: decoded, encoding: .utf8) == "firstsecond")
    }

    // MARK: - LZ4

    /// Kafka uses the LZ4 FRAME format. Compression.framework's COMPRESSION_LZ4 is Apple's own
    /// container with a `bv41` magic, so reaching for it yields corrupt output, not an error.
    @Test("An LZ4 frame of stored blocks decodes")
    func lz4UncompressedBlockFrame() throws {
        var frame: [UInt8] = [0x04, 0x22, 0x4D, 0x18]
        frame.append(0x60)                                   // FLG: version 01, block independence
        frame.append(0x70)                                   // BD: 4 MB max block size
        frame.append(0x00)                                   // header checksum, not verified
        let body = Array("lz4 stored block".utf8)
        let size = UInt32(body.count) | 0x8000_0000          // high bit: stored, not compressed
        frame.append(contentsOf: [
            UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF),
            UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)
        ])
        frame.append(contentsOf: body)
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // EndMark

        let decoded = try KafkaCompression.decompress(Data(frame), codec: .lz4)
        #expect(String(data: decoded, encoding: .utf8) == "lz4 stored block")
    }

    @Test("A payload that is not an LZ4 frame is reported")
    func lz4RejectsNonFrames() {
        #expect(throws: KafkaError.self) {
            _ = try KafkaCompression.decompress(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]), codec: .lz4)
        }
    }

    // MARK: - zstd

    /// zstd has no macOS system library at all, verified by dlopen: libarchive exports no
    /// ZSTD_ symbol and libzstd.dylib does not exist. This comes from the upstream SPM package.
    @Test("A zstd frame decompresses")
    func zstdRoundTrip() throws {
        let compressed = try Self.zstdCompress(Self.payload)
        #expect(compressed.prefix(4) == Data([0x28, 0xB5, 0x2F, 0xFD]))
        #expect(try KafkaCompression.decompress(compressed, codec: .zstd) == Self.payload)
    }

    @Test("A zstd frame larger than one buffer decompresses whole")
    func zstdLargePayload() throws {
        let large = Data((0 ..< 300_000).map { UInt8($0 % 241) })
        let compressed = try Self.zstdCompress(large)
        #expect(try KafkaCompression.decompress(compressed, codec: .zstd) == large)
    }

    @Test("A payload that is not a zstd frame is reported")
    func zstdRejectsNonFrames() {
        #expect(throws: KafkaError.self) {
            _ = try KafkaCompression.decompress(Data([0x00, 0x01, 0x02, 0x03, 0x04]), codec: .zstd)
        }
    }

    // MARK: - Helpers

    private static func gzip(_ data: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.closeFile()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return compressed
    }

    /// Round-tripped through the same library the decoder uses, so this proves the wiring and
    /// the buffer growth rather than the algorithm.
    private static func zstdCompress(_ data: Data) throws -> Data {
        let bound = ZSTD_compressBound(data.count)
        var destination = [UInt8](repeating: 0, count: bound)
        let bytes = [UInt8](data)
        let written = bytes.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { target -> Int in
                guard let sourceBase = source.baseAddress, let targetBase = target.baseAddress else { return 0 }
                return ZSTD_compress(targetBase, target.count, sourceBase, source.count, 3)
            }
        }
        guard ZSTD_isError(written) == 0 else {
            throw KafkaError.decompressionFailed(codec: "zstd", reason: "test fixture failed to compress")
        }
        return Data(destination.prefix(written))
    }
}
