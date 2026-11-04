import Compression
import Foundation
import TableProWireIO

public struct ZipEntryReader: ~Copyable {
    public let entry: ZipArchive.Entry
    private var budget: DecompressionBudget
    private let payload: UnsafeBufferPointer<UInt8>
    private let inflater: UnsafeMutablePointer<compression_stream>?
    private var storedOffset = 0
    private var recordedConsumed = 0
    private var isFinished: Bool
    public private(set) var bytesProduced = 0

    init(entry: ZipArchive.Entry, payload: UnsafeBufferPointer<UInt8>, budget: DecompressionBudget = .standard) throws {
        self.entry = entry
        self.payload = payload
        self.budget = budget
        switch entry.compressionMethod {
        case ZipArchive.storedMethod:
            inflater = nil
            isFinished = payload.isEmpty
        case ZipArchive.deflateMethod:
            guard let base = payload.baseAddress, !payload.isEmpty else {
                inflater = nil
                isFinished = true
                return
            }
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                stream.deallocate()
                throw ZipArchive.Failure.corruptEntry(entry.path)
            }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = payload.count
            inflater = stream
            isFinished = false
        default:
            throw ZipArchive.Failure.unsupportedCompression(entry.compressionMethod)
        }
    }

    deinit {
        guard let inflater else { return }
        compression_stream_destroy(inflater)
        inflater.deallocate()
    }

    public var compressedBytesConsumed: Int {
        guard let inflater else { return storedOffset }
        return payload.count - inflater.pointee.src_size
    }

    public var fractionConsumed: Double {
        guard !payload.isEmpty else { return 1 }
        return Double(compressedBytesConsumed) / Double(payload.count)
    }

    public mutating func read(into destination: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        guard !isFinished, let destinationBase = destination.baseAddress, !destination.isEmpty else { return 0 }
        guard let inflater else {
            let copied = readStored(into: destinationBase, capacity: destination.count)
            bytesProduced += copied
            try record(copied)
            return copied
        }
        inflater.pointee.dst_ptr = destinationBase
        inflater.pointee.dst_size = destination.count
        let status = compression_stream_process(inflater, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        let produced = destination.count - inflater.pointee.dst_size
        switch status {
        case COMPRESSION_STATUS_END:
            isFinished = true
            try account(produced)
            return produced
        case COMPRESSION_STATUS_OK where produced > 0:
            try account(produced)
            return produced
        default:
            isFinished = true
            throw ZipArchive.Failure.corruptEntry(entry.path)
        }
    }

    private mutating func account(_ produced: Int) throws {
        bytesProduced += produced
        guard bytesProduced <= entry.uncompressedSize else {
            isFinished = true
            throw ZipArchive.Failure.corruptEntry(entry.path)
        }
        try record(produced)
    }

    private mutating func record(_ produced: Int) throws {
        let consumed = compressedBytesConsumed
        do {
            try budget.record(produced: produced, consumed: consumed - recordedConsumed)
        } catch {
            isFinished = true
            throw ZipArchive.Failure.entryTooLarge(entry.path)
        }
        recordedConsumed = consumed
    }

    private mutating func readStored(into destination: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        guard let source = payload.baseAddress else {
            isFinished = true
            return 0
        }
        let count = min(capacity, payload.count - storedOffset)
        UnsafeMutableRawPointer(destination).copyMemory(from: source + storedOffset, byteCount: count)
        storedOffset += count
        isFinished = storedOffset >= payload.count
        return count
    }
}
