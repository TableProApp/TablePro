import Foundation
import zlib

// zlib's gzip mode (window bits + 16) writes the header and the CRC and length trailer that gzip -d checks. The raw
// mode (negative window bits) writes a bare deflate stream with neither, which is what a ZIP entry of method 8 holds.
public final class GzipDeflater {
    public enum Container: Sendable {
        case gzip
        case raw
    }

    public enum Level: Sendable {
        case standard
        case fastest

        var zlibLevel: Int32 {
            switch self {
            case .standard: Z_DEFAULT_COMPRESSION
            case .fastest: Z_BEST_SPEED
            }
        }
    }

    private let stream: UnsafeMutablePointer<z_stream>
    private let chunk: UnsafeMutableBufferPointer<UInt8>
    private var finished = false

    private static let chunkSize = 256 * 1_024

    public init(container: Container = .gzip, level: Level = .standard) throws(GzipError) {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        chunk = .allocate(capacity: Self.chunkSize)
        let windowBits = container == .gzip ? 16 + MAX_WBITS : -MAX_WBITS
        let status = deflateInit2_(
            stream, level.zlibLevel, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            chunk.deallocate()
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw .compressionFailed
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
        chunk.deallocate()
    }

    public func deflate(
        _ input: UnsafeRawBufferPointer,
        into sink: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard !finished else { throw GzipError.compressionFailed }
        guard let base = input.bindMemory(to: UInt8.self).baseAddress, !input.isEmpty else { return }
        var cursor = 0
        while cursor < input.count {
            let take = min(input.count - cursor, Int(UInt32.max))
            stream.pointee.next_in = UnsafeMutablePointer(mutating: base + cursor)
            stream.pointee.avail_in = uInt(take)
            try drain(flush: Z_NO_FLUSH, into: sink)
            cursor += take
        }
    }

    // A sync flush writes out everything taken so far and keeps the window, so the bytes written are the
    // stream's exact size up to here at the cost of a few bytes, not of the compression ratio.
    public func flush(into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !finished else { throw GzipError.compressionFailed }
        stream.pointee.next_in = nil
        stream.pointee.avail_in = 0
        try drain(flush: Z_SYNC_FLUSH, into: sink)
    }

    public func finish(into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !finished else { return }
        stream.pointee.next_in = nil
        stream.pointee.avail_in = 0
        try drain(flush: Z_FINISH, into: sink)
        finished = true
    }

    // Runs deflate until it has taken all its input and, on Z_FINISH, written the trailer.
    private func drain(flush: Int32, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        while true {
            stream.pointee.next_out = chunk.baseAddress
            stream.pointee.avail_out = uInt(chunk.count)
            let status = zlib.deflate(stream, flush)
            let produced = chunk.count - Int(stream.pointee.avail_out)
            switch status {
            case Z_OK, Z_BUF_ERROR, Z_STREAM_END:
                break
            default:
                throw GzipError.compressionFailed
            }
            if produced > 0 {
                try sink(UnsafeRawBufferPointer(start: chunk.baseAddress, count: produced))
            }
            if flush == Z_FINISH {
                if status == Z_STREAM_END { return }
                guard produced > 0 else { throw GzipError.compressionFailed }
            } else if stream.pointee.avail_in == 0, stream.pointee.avail_out > 0 {
                return
            }
        }
    }

    public static func compress(_ data: Data) throws -> Data {
        var output = Data()
        let deflater = try GzipDeflater()
        let sink: (UnsafeRawBufferPointer) throws -> Void = { output.append($0.assumingMemoryBound(to: UInt8.self)) }
        try data.withUnsafeBytes { try deflater.deflate($0, into: sink) }
        try deflater.finish(into: sink)
        return output
    }
}
