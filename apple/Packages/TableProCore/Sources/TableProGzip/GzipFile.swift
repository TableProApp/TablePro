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
            while let block = try input.read(upToCount: readSize), !block.isEmpty {
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

    private static func sizeLimit(_ limit: Int) -> DecompressionBudget {
        DecompressionBudget(limit: limit, ratioLimit: .max, grace: .max)
    }
}
