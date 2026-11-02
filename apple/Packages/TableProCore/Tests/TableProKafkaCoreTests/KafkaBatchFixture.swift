import Foundation
import TableProKafkaCore
import zlib

enum KafkaBatchFixture {
    static let transactional: Int16 = 0x10
    static let control: Int16 = 0x20

    // The decoder never reads the CRC, so it stays zero.
    static func batch(
        baseOffset: Int64 = 0,
        baseTimestamp: Int64 = 1_700_000_000_000,
        codec: KafkaCompressionCodec = .none,
        flags: Int16 = 0,
        producerId: Int64 = -1,
        recordCount: Int32 = 1,
        payload: Data
    ) -> Data {
        var body = KafkaProtocolWriter()
        body.int32(-1)                                       // partitionLeaderEpoch
        body.int8(2)                                         // magic
        body.uint32(0)                                       // crc
        body.int16(codec.rawValue | flags)                   // attributes
        body.int32(recordCount - 1)                          // lastOffsetDelta
        body.int64(baseTimestamp)
        body.int64(baseTimestamp)                            // maxTimestamp
        body.int64(producerId)
        body.int16(-1)                                       // producerEpoch
        body.int32(-1)                                       // baseSequence
        body.int32(recordCount)
        body.raw(payload)

        var batch = KafkaProtocolWriter()
        batch.int64(baseOffset)
        batch.int32(Int32(body.count))
        batch.raw(body.bytes)
        return batch.data
    }

    static func record(offsetDelta: Int32 = 0, timestampDelta: Int64 = 0, value: Data?) -> Data {
        var fields = KafkaProtocolWriter()
        fields.int8(0)
        fields.varlong(timestampDelta)
        fields.varint(offsetDelta)
        fields.varint(-1)                                    // null key
        if let value {
            fields.varint(Int32(value.count))
            fields.raw(value)
        } else {
            fields.varint(-1)
        }
        fields.varint(0)                                     // header count
        var framed = KafkaProtocolWriter()
        framed.varint(Int32(fields.count))
        framed.raw(fields.bytes)
        return framed.data
    }

    // The bytes around a value of `valueLength` zeros, so a large value never has to exist uncompressed.
    static func zeroValueRecord(offsetDelta: Int32 = 0, valueLength: Int) -> (head: Data, tail: Data) {
        var fields = KafkaProtocolWriter()
        fields.int8(0)
        fields.varlong(0)
        fields.varint(offsetDelta)
        fields.varint(-1)
        fields.varint(Int32(valueLength))
        var tail = KafkaProtocolWriter()
        tail.varint(0)
        var head = KafkaProtocolWriter()
        head.varint(Int32(fields.count + valueLength + tail.count))
        head.raw(fields.bytes)
        return (head.data, tail.data)
    }

    static func gzip(_ head: Data, zeros: Int = 0, _ tail: Data = Data()) -> Data {
        var stream = z_stream()
        let status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        precondition(status == Z_OK, "deflateInit2_ failed")
        defer { deflateEnd(&stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)

        func feed(_ bytes: [UInt8], _ flush: Int32) {
            var input = bytes
            input.withUnsafeMutableBufferPointer { source in
                stream.next_in = source.baseAddress
                stream.avail_in = uInt(source.count)
                repeat {
                    chunk.withUnsafeMutableBufferPointer { target in
                        stream.next_out = target.baseAddress
                        stream.avail_out = uInt(target.count)
                        deflate(&stream, flush)
                        output.append(contentsOf: target.prefix(target.count - Int(stream.avail_out)))
                    }
                } while stream.avail_out == 0
            }
        }

        feed([UInt8](head), Z_NO_FLUSH)
        let zeroBlock = [UInt8](repeating: 0, count: 1 << 16)
        var left = zeros
        while left > 0 {
            let take = min(left, zeroBlock.count)
            feed(Array(zeroBlock.prefix(take)), Z_NO_FLUSH)
            left -= take
        }
        feed([UInt8](tail), Z_FINISH)
        return output
    }

    static let xerialHeader: [UInt8] = [0x82, 0x53, 0x4E, 0x41, 0x50, 0x50, 0x59, 0x00, 0, 0, 0, 1, 0, 0, 0, 1]

    static func xerial(_ blocks: [[UInt8]]) -> Data {
        var framed = xerialHeader
        for block in blocks {
            let length = UInt32(block.count)
            framed += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }
            framed += block
        }
        return Data(framed)
    }

    static func varint(_ value: Int) -> [UInt8] {
        var encoded: [UInt8] = []
        var remaining = value
        while remaining >= 0x80 {
            encoded.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        encoded.append(UInt8(remaining))
        return encoded
    }

    // One snappy block of a single literal, up to 64 KiB.
    static func snappyLiteral(_ bytes: [UInt8]) -> [UInt8] {
        let length = bytes.count - 1
        let tag: [UInt8]
        if length < 60 {
            tag = [UInt8(length) << 2]
        } else if length < 256 {
            tag = [60 << 2, UInt8(length)]
        } else {
            tag = [61 << 2, UInt8(length & 0xFF), UInt8(length >> 8)]
        }
        return varint(bytes.count) + tag + bytes
    }

    // Frame flags 0x60 and 64 KiB blocks, with the header checksum the reference lz4 tool expects.
    static func lz4Frame(_ blocks: [(bytes: [UInt8], compressed: Bool)]) -> Data {
        var frame: [UInt8] = [0x04, 0x22, 0x4D, 0x18, 0x60, 0x40, 0x82]
        for block in blocks {
            let size = UInt32(block.bytes.count) | (block.compressed ? 0 : 0x8000_0000)
            frame += [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: size >> $0) }
            frame += block.bytes
        }
        frame += [0, 0, 0, 0]
        return Data(frame)
    }

    // Frame flags 0x60 and 4 MiB blocks, each block a single literal byte.
    static func lz4FrameOfOneByteBlocks(_ byte: UInt8, count: Int) -> Data {
        var blocks: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x10, byte]
        while blocks.count < count * 6 { blocks += blocks }
        return Data([0x04, 0x22, 0x4D, 0x18, 0x60, 0x70, 0x73] + blocks.prefix(count * 6) + [0, 0, 0, 0])
    }

    // A block holding one literal-only sequence, which is a complete LZ4 block.
    static func lz4Literal(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count >= 15 else { return [UInt8(bytes.count) << 4] + bytes }
        var block: [UInt8] = [0xF0]
        var remaining = bytes.count - 15
        while remaining >= 255 {
            block.append(255)
            remaining -= 255
        }
        block.append(UInt8(remaining))
        return block + bytes
    }

    static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func zstdBlockHeader(size: Int, rle: Bool, last: Bool) -> [UInt8] {
        let value = size << 3 | (rle ? 1 : 0) << 1 | (last ? 1 : 0)
        return [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)]
    }

    // A frame that declares no content size, with a 1 MiB window, holding `bytes` as one raw block.
    static func zstdRawFrame(_ bytes: [UInt8]) -> Data {
        Data(zstdMagic + [0x00, 0x50] + zstdBlockHeader(size: bytes.count, rle: false, last: true) + bytes)
    }

    // A frame that declares no content size and repeats one byte for `blocks` blocks of 128 KiB.
    static func zstdRunFrame(of byte: UInt8, blocks: Int) -> Data {
        var frame = zstdMagic + [0x00, 0x50]
        for index in 0 ..< blocks {
            frame += zstdBlockHeader(size: 128 * 1_024, rle: true, last: index == blocks - 1)
            frame.append(byte)
        }
        return Data(frame)
    }
}

func refusedCodec(_ error: KafkaError?) -> String? {
    guard case .decompressionExceeded(let codec)? = error else { return nil }
    return codec
}
