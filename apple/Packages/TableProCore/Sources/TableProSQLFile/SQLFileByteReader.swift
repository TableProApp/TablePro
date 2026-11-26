import Foundation
import TableProGzip
import TableProWireIO

/// The bytes of a dump as the parser reads them: the file itself, or the SQL inside a gzip file,
/// inflated as it is read so nothing is written to disk. A gzip file is told by its magic number,
/// which no text dump can start with.
public final class SQLFileByteReader {
    private static let gzipMagic: [UInt8] = [0x1F, 0x8B]

    // Nothing is written, so the disk budget a copy needs does not apply, and the parser's span
    // limit bounds memory.
    private static let streamingBudget = DecompressionBudget(ratioLimit: .max, grace: .max)

    private let handle: FileHandle
    private var inflater: GzipInflater?
    private var pendingInput = Data()
    private var reachedEnd = false

    /// The file's size on disk, and how much of it has been read: compressed bytes for a gzip file.
    public private(set) var fileSize: Int64 = 0
    public private(set) var bytesRead: Int64 = 0

    public var isCompressed: Bool { inflater != nil }

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        var info = stat()
        fileSize = fstat(handle.fileDescriptor, &info) == 0 ? Int64(info.st_size) : 0
        let head = try autoreleasepool { try handle.read(upToCount: 2) } ?? Data()
        try handle.seek(toOffset: 0)
        if Array(head) == Self.gzipMagic {
            inflater = try GzipInflater(budget: Self.streamingBudget)
        }
    }

    deinit {
        try? handle.close()
    }

    /// The next bytes of SQL, about `count` of them; empty once the file ends.
    public func read(upToCount count: Int) throws -> Data {
        guard let inflater else {
            guard !reachedEnd else { return Data() }
            let block = try autoreleasepool { try handle.read(upToCount: count) } ?? Data()
            bytesRead += Int64(block.count)
            if block.isEmpty { reachedEnd = true }
            return block
        }
        var inflated = Data()
        while inflated.count < count, !reachedEnd {
            if pendingInput.isEmpty {
                let block = try autoreleasepool { try handle.read(upToCount: count) } ?? Data()
                bytesRead += Int64(block.count)
                guard !block.isEmpty else {
                    reachedEnd = true
                    try inflater.finish()
                    break
                }
                pendingInput = block
            }
            // Fed a slice at a time, so one compressed block of zero-filled rows inflates no more than a slice's worth
            // past the size asked for, however far it packs.
            let slice = pendingInput.prefix(Self.inflateSlice)
            pendingInput = pendingInput.dropFirst(slice.count)
            try slice.withUnsafeBytes { raw in
                try inflater.inflate(raw) { inflated.append($0.assumingMemoryBound(to: UInt8.self)) }
            }
        }
        return inflated
    }

    // Deflate packs at most about 1,032 to 1, so 4 KiB of input inflates to at most about 4 MiB.
    private static let inflateSlice = 4 * 1_024

    public func close() throws {
        try handle.close()
    }

    /// The first `limit` bytes of SQL in the file, for a preview, and whether they are all of it.
    public static func leadingBytes(of url: URL, limit: Int) throws -> (data: Data, isWholeFile: Bool) {
        let reader = try SQLFileByteReader(url: url)
        var data = Data()
        while data.count < limit {
            let block = try reader.read(upToCount: 256 * 1_024)
            guard !block.isEmpty else { return (data, true) }
            data.append(block)
        }
        return (data.prefix(limit), false)
    }
}
