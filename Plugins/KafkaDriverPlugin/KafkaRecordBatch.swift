import Foundation

/// One entry from a Fetch response's aborted-transaction list. Both halves matter: the
/// producer owns the run and the offset says where it starts.
struct KafkaAbortedTransaction: Sendable {
    let producerId: Int64
    let firstOffset: Int64
}

struct KafkaRecordHeader: Sendable {
    let key: String
    let value: Data?
}

struct KafkaRecord: Sendable {
    let offset: Int64
    let timestamp: Int64
    let timestampIsLogAppendTime: Bool
    let key: Data?
    let value: Data?
    let headers: [KafkaRecordHeader]
    let partition: Int32
}

enum KafkaCompressionCodec: Int16, Sendable {
    case none = 0
    case gzip = 1
    case snappy = 2
    case lz4 = 3
    case zstd = 4

    var name: String {
        switch self {
        case .none: return "none"
        case .gzip: return "gzip"
        case .snappy: return "snappy"
        case .lz4: return "lz4"
        case .zstd: return "zstd"
        }
    }
}

/// Decoder for the v2 record batch (magic byte 2), which is the only format Kafka has written
/// since 0.11. The older v0/v1 message sets are not read: a broker still storing them is more
/// than eight years old, and guessing at a half-supported legacy path is worse than saying so.
enum KafkaRecordBatchDecoder {
    /// Fixed bytes from `baseOffset` to the record count, inclusive. Measured against a real
    /// broker's batches, and it is also what Kafka's DefaultRecordBatch documents.
    static let headerLength = 61

    /// Fixed offsets into a v2 batch header, so it can be read in place without slicing.
    private static func int16(_ bytes: [UInt8], at index: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
    }

    private static func int32(_ bytes: [UInt8], at index: Int) -> Int32 {
        var value: UInt32 = 0
        for offset in 0 ..< 4 { value = value << 8 | UInt32(bytes[index + offset]) }
        return Int32(bitPattern: value)
    }

    private static func int64(_ bytes: [UInt8], at index: Int) -> Int64 {
        var value: UInt64 = 0
        for offset in 0 ..< 8 { value = value << 8 | UInt64(bytes[index + offset]) }
        return Int64(bitPattern: value)
    }

    private static let compressionMask: Int16 = 0x07
    private static let logAppendTimeMask: Int16 = 0x08
    private static let controlBatchMask: Int16 = 0x20

    /// Decodes every batch in one partition's records blob.
    ///
    /// Two shapes here are not optional. The blob is a SEQUENCE of batches, not one batch, and
    /// the broker truncates it at `partition_max_bytes` mid-batch, so a trailing partial batch
    /// is normal and must be dropped rather than treated as corruption. And a control batch
    /// (the transaction commit and abort markers) carries records whose payload is internal
    /// bookkeeping: surfacing them would put marker rows in the user's grid.
    static func decode(
        blob: Data,
        partition: Int32,
        abortedTransactions: [KafkaAbortedTransaction] = [],
        skipAborted: Bool
    ) throws -> (records: [KafkaRecord], truncated: Bool) {
        let bytes = [UInt8](blob)
        var cursor = 0
        var records: [KafkaRecord] = []
        var truncated = false
        // A partition can carry several producers at once, so an aborted run belongs to its
        // producer. Keying this on the offset alone let one producer's commit marker end
        // another's aborted run, and its rolled-back records then reached the grid.
        var abortedProducers = Set<Int64>()

        while cursor + headerLength <= bytes.count {
            // Read the header in place. Re-slicing the remaining blob per batch made decoding
            // quadratic in the fetch size, and a 64 MB fetch of small batches is the case that
            // the byte-budget escalation produces.
            let baseOffset = Self.int64(bytes, at: cursor)
            let batchLength = Int(Self.int32(bytes, at: cursor + 8))
            let end = cursor + 12 + batchLength
            // `end` must clear the batch's own 61-byte header as well as fitting the blob, or
            // the payload slice below runs backwards.
            guard batchLength >= 0, end <= bytes.count, end >= cursor + headerLength else {
                truncated = true
                break
            }
            let magic = Int8(bitPattern: bytes[cursor + 16])
            guard magic == 2 else {
                throw KafkaError.malformedResponse(
                    "record batch magic \(magic) is not supported; TablePro reads the v2 format only"
                )
            }
            let attributes = Self.int16(bytes, at: cursor + 21)
            let baseTimestamp = Self.int64(bytes, at: cursor + 27)
            let producerId = Self.int64(bytes, at: cursor + 43)
            let count = Int(Self.int32(bytes, at: cursor + 57))

            let isControl = attributes & controlBatchMask != 0
            let isTransactional = attributes & 0x10 != 0
            let logAppendTime = attributes & logAppendTimeMask != 0
            guard let codec = KafkaCompressionCodec(rawValue: attributes & compressionMask) else {
                throw KafkaError.unsupportedCompression("codec \(attributes & compressionMask)")
            }

            if skipAborted, isTransactional,
               abortedTransactions.contains(where: { $0.producerId == producerId && $0.firstOffset <= baseOffset }) {
                abortedProducers.insert(producerId)
            }

            if isControl {
                // A control batch is its producer's commit or abort marker, and ends only that
                // producer's run.
                abortedProducers.remove(producerId)
                cursor = end
                continue
            }

            let payload = Data(bytes[(cursor + headerLength) ..< end])
            let decoded = try KafkaCompression.decompress(payload, codec: codec)
            let shouldSkip = skipAborted && abortedProducers.contains(producerId)
            if !shouldSkip {
                records.append(contentsOf: try decodeRecords(
                    decoded,
                    count: count,
                    baseOffset: baseOffset,
                    baseTimestamp: baseTimestamp,
                    logAppendTime: logAppendTime,
                    partition: partition
                ))
            }
            cursor = end
        }

        if cursor < bytes.count { truncated = true }
        return (records, truncated)
    }

    /// The records inside a batch use ZIG-ZAG signed varints, unlike the unsigned LEB128 the
    /// protocol frame uses. The two look identical on the wire and mixing them up decodes
    /// small values plausibly while corrupting large ones.
    private static func decodeRecords(
        _ payload: Data,
        count: Int,
        baseOffset: Int64,
        baseTimestamp: Int64,
        logAppendTime: Bool,
        partition: Int32
    ) throws -> [KafkaRecord] {
        var reader = KafkaProtocolReader(payload)
        var records: [KafkaRecord] = []
        // `count` is read straight off the wire. A record needs at least a few bytes, so the
        // payload length is a real ceiling on how many there can be; reserving on the claim
        // alone lets a corrupt batch ask for billions of slots.
        records.reserveCapacity(min(max(0, count), payload.count / 4 + 1))

        for _ in 0 ..< max(0, count) {
            if reader.isAtEnd { break }
            let length = Int(try reader.varint())
            let start = reader.offset
            _ = try reader.int8()                            // per-record attributes, unused
            let timestampDelta = try reader.varlong()
            let offsetDelta = try reader.varint()
            let key = try varintPrefixedBytes(&reader)
            let value = try varintPrefixedBytes(&reader)
            let headerCount = Int(try reader.varint())
            var headers: [KafkaRecordHeader] = []
            headers.reserveCapacity(max(0, min(headerCount, 64)))
            for _ in 0 ..< max(0, headerCount) {
                let keyLength = Int(try reader.varint())
                guard keyLength >= 0 else {
                    throw KafkaError.malformedResponse("record header key length is negative")
                }
                let keyData = try varintFixedBytes(&reader, length: keyLength)
                let headerValue = try varintPrefixedBytes(&reader)
                headers.append(KafkaRecordHeader(
                    key: String(data: keyData, encoding: .utf8) ?? keyData.hexString,
                    value: headerValue
                ))
            }
            if length >= 0, reader.offset != start + length {
                throw KafkaError.malformedResponse(
                    "record length \(length) disagrees with \(reader.offset - start) decoded bytes"
                )
            }
            records.append(KafkaRecord(
                offset: baseOffset + Int64(offsetDelta),
                timestamp: baseTimestamp + timestampDelta,
                timestampIsLogAppendTime: logAppendTime,
                key: key,
                value: value,
                headers: headers,
                partition: partition
            ))
        }
        return records
    }

    private static func varintPrefixedBytes(_ reader: inout KafkaProtocolReader) throws -> Data? {
        let length = Int(try reader.varint())
        if length < 0 { return nil }
        return try varintFixedBytes(&reader, length: length)
    }

    private static func varintFixedBytes(_ reader: inout KafkaProtocolReader, length: Int) throws -> Data {
        guard length >= 0, length <= reader.remaining else {
            throw KafkaError.truncatedResponse(needed: length, available: reader.remaining)
        }
        var slice = Data()
        slice.reserveCapacity(length)
        for _ in 0 ..< length {
            slice.append(try reader.uint8())
        }
        return slice
    }
}

/// Builds the single-record v2 batch that PRODUCE sends. The CRC is mandatory and covers the
/// batch from the attributes field to the end, not the whole batch.
enum KafkaRecordBatchEncoder {
    static func singleRecordBatch(
        key: Data?,
        value: Data?,
        headers: [KafkaRecordHeader],
        timestamp: Int64
    ) -> Data {
        var record = KafkaProtocolWriter()
        record.int8(0)
        record.varlong(0)
        record.varint(0)
        varintPrefixed(&record, key)
        varintPrefixed(&record, value)
        record.varint(Int32(headers.count))
        for header in headers {
            let keyBytes = Data(header.key.utf8)
            record.varint(Int32(keyBytes.count))
            record.raw(keyBytes)
            varintPrefixed(&record, header.value)
        }

        var framedRecord = KafkaProtocolWriter()
        framedRecord.varint(Int32(record.count))
        framedRecord.raw(record.bytes)

        // From attributes to the end: this is exactly the range the CRC covers.
        var body = KafkaProtocolWriter()
        body.int16(0)                                        // attributes: no compression
        body.int32(0)                                        // lastOffsetDelta
        body.int64(timestamp)                                // baseTimestamp
        body.int64(timestamp)                                // maxTimestamp
        body.int64(-1)                                       // producerId
        body.int16(-1)                                       // producerEpoch
        body.int32(-1)                                       // baseSequence
        body.int32(1)                                        // record count
        body.raw(framedRecord.bytes)

        var afterLength = KafkaProtocolWriter()
        afterLength.int32(-1)                                // partitionLeaderEpoch
        afterLength.int8(2)                                  // magic
        afterLength.uint32(KafkaCRC32C.checksum(body.bytes))
        afterLength.raw(body.bytes)

        var batch = KafkaProtocolWriter()
        batch.int64(0)                                       // baseOffset, assigned by the broker
        batch.int32(Int32(afterLength.count))
        batch.raw(afterLength.bytes)
        return batch.data
    }

    private static func varintPrefixed(_ writer: inout KafkaProtocolWriter, _ value: Data?) {
        guard let value else {
            writer.varint(-1)
            return
        }
        writer.varint(Int32(value.count))
        writer.raw(value)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
