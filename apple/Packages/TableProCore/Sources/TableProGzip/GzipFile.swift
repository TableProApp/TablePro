import Foundation
import TableProWireIO

public enum GzipFile {
    private static let readSize = 256 * 1_024

    // What a decompressed file leaves free on its volume, or half the free space on a fuller one, so a small file
    // cannot fill the disk.
    public static let reservedSpace = 2 << 30

    // A file the user picked gets no expansion ratio, since a dump of zero-filled BLOBs packs past
    // 500:1. Its output stops short of the volume's free space instead.
    public static func budget(writingTo destination: URL) -> DecompressionBudget {
        let values = try? destination.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage.map { Int(clamping: $0) }
            ?? values?.volumeAvailableCapacity
        return budget(availableSpace: available)
    }

    public static func budget(availableSpace: Int?) -> DecompressionBudget {
        sizeLimit(availableSpace.map { max($0, 0) - min(reservedSpace, max($0, 0) / 2) } ?? .max)
    }

    // The destination is removed on any failure, so a refused or cancelled file leaves nothing behind.
    @concurrent
    public static func decompress(
        source: URL,
        destination: URL,
        outputLimit: Int? = nil
    ) async throws {
        let budget = outputLimit.map(Self.sizeLimit) ?? Self.budget(writingTo: destination)
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path(percentEncoded: false)])
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let inflater = try GzipInflater(budget: budget)
            // Each read returns an autoreleased buffer, and this loop never suspends, so nothing drains them until it ends.
            while let block = try autoreleasepool(invoking: { try input.read(upToCount: readSize) }), !block.isEmpty {
                try Task.checkCancellation()
                try block.withUnsafeBytes { raw in
                    try inflater.inflate(raw) { try output.write(contentsOf: $0) }
                }
            }
            try inflater.finish()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            // With no ratio in the budget, only the size limit refuses a file.
            if (error as? GzipError) == .expandsTooFar { throw GzipError.needsMoreDiskSpace }
            throw error
        }
    }

    // Throws CancellationError once `isCancelled` answers true, checked before every chunk; the caller maps it.
    public static func compress(
        source: URL,
        into output: FileHandle,
        isCancelled: () -> Bool,
        progress: ((_ bytesRead: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var info = stat()
        let total = fstat(input.fileDescriptor, &info) == 0 ? Int64(info.st_size) : 0
        let deflater = try GzipDeflater()
        let sink: (UnsafeRawBufferPointer) throws -> Void = { try output.write(contentsOf: $0) }
        var bytesRead: Int64 = 0
        progress?(0, total)
        // Each read returns an autoreleased buffer, and this loop never suspends, so nothing drains them until it ends.
        while let block = try autoreleasepool(invoking: { try input.read(upToCount: readSize) }), !block.isEmpty {
            if isCancelled() { throw CancellationError() }
            try block.withUnsafeBytes { try deflater.deflate($0, into: sink) }
            bytesRead += Int64(block.count)
            progress?(bytesRead, total)
        }
        if isCancelled() { throw CancellationError() }
        try deflater.finish(into: sink)
    }

    // The destination is removed on any failure, so a stopped or failed compression leaves nothing behind.
    public static func compress(
        source: URL,
        to destination: URL,
        isCancelled: () -> Bool,
        progress: ((_ bytesRead: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) throws {
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path(percentEncoded: false)])
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            do {
                try compress(source: source, into: output, isCancelled: isCancelled, progress: progress)
            } catch {
                try? output.close()
                throw error
            }
            // A volume can report a deferred write failure only at close.
            try output.close()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func sizeLimit(_ limit: Int) -> DecompressionBudget {
        DecompressionBudget(limit: limit, ratioLimit: .max, grace: .max)
    }
}
