import Foundation
import TableProWireIO
import zlib

public enum GzipError: Error, Equatable, Sendable, LocalizedError {
    case corrupt
    case truncated
    case expandsTooFar
    case needsMoreDiskSpace

    public var errorDescription: String? {
        switch self {
        case .corrupt:
            return String(localized: "The gzip data is corrupt.")
        case .truncated:
            return String(localized: "The gzip data ends before its last block.")
        case .expandsTooFar:
            return String(localized: "The compressed data expands to far more than it holds, so it was not read.")
        case .needsMoreDiskSpace:
            return String(localized: "The decompressed file needs more free disk space than this Mac has.")
        }
    }
}

// zlib's own gzip mode (window bits + 16) reads the header, checks the CRC and the length, and
// handles every member of a concatenated file the way gzip -d does.
public final class GzipInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var budget: DecompressionBudget
    private var memberEnded = false
    private var ignoringTrailer = false
    private let chunk: UnsafeMutableBufferPointer<UInt8>

    private static let chunkSize = 256 * 1_024
    private static let gzipMagic: UInt8 = 0x1F

    public init(budget: DecompressionBudget = .standard) throws(GzipError) {
        self.budget = budget
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        chunk = .allocate(capacity: Self.chunkSize)
        guard inflateInit2_(stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            chunk.deallocate()
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw .corrupt
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
        chunk.deallocate()
    }

    public var bytesProduced: Int { budget.produced }

    public func inflate(
        _ input: UnsafeRawBufferPointer,
        into sink: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard !ignoringTrailer, let base = input.bindMemory(to: UInt8.self).baseAddress, !input.isEmpty else { return }
        var cursor = 0
        var outputPending = false
        while cursor < input.count || outputPending {
            if memberEnded {
                // Padding after the last member is ignored, as gzip -d ignores trailing garbage.
                guard base[cursor] == Self.gzipMagic else {
                    ignoringTrailer = true
                    return
                }
                guard inflateReset(stream) == Z_OK else { throw GzipError.corrupt }
                memberEnded = false
            }
            stream.pointee.next_in = UnsafeMutablePointer(mutating: base + cursor)
            stream.pointee.avail_in = uInt(min(input.count - cursor, Int(UInt32.max)))
            let availableBefore = Int(stream.pointee.avail_in)
            stream.pointee.next_out = chunk.baseAddress
            stream.pointee.avail_out = uInt(chunk.count)
            let status = zlib.inflate(stream, Z_NO_FLUSH)
            let consumed = availableBefore - Int(stream.pointee.avail_in)
            let produced = chunk.count - Int(stream.pointee.avail_out)
            cursor += consumed
            switch status {
            case Z_OK, Z_BUF_ERROR, Z_STREAM_END:
                break
            default:
                throw GzipError.corrupt
            }
            do {
                try budget.record(produced: produced, consumed: consumed)
            } catch {
                throw GzipError.expandsTooFar
            }
            if produced > 0 {
                try sink(UnsafeRawBufferPointer(start: chunk.baseAddress, count: produced))
            }
            // A full output chunk can leave inflated bytes inside zlib after the input is used up.
            outputPending = status != Z_STREAM_END && stream.pointee.avail_out == 0
            if status == Z_STREAM_END {
                memberEnded = true
                if cursor >= input.count { return }
            } else if consumed == 0, produced == 0 {
                guard cursor < input.count else { return }
                throw GzipError.corrupt
            }
        }
    }

    public func finish() throws(GzipError) {
        guard memberEnded || ignoringTrailer else { throw .truncated }
    }

    public static func decompress(_ data: Data, budget: DecompressionBudget = .standard) throws -> Data {
        var output = Data()
        try decompress(data, budget: budget) { output.append($0.assumingMemoryBound(to: UInt8.self)) }
        return output
    }

    public static func decompress(
        _ data: Data,
        budget: DecompressionBudget = .standard,
        into sink: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let inflater = try GzipInflater(budget: budget)
        try data.withUnsafeBytes { try inflater.inflate($0, into: sink) }
        try inflater.finish()
    }
}
