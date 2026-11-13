#if canImport(Darwin)
import Darwin
import Foundation
import TableProWireIO
import Testing

private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "spool-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

// The open descriptors whose file was made with this prefix, named or not: F_GETPATH still names an unlinked file.
private func openFiles(prefix: String) -> [(nlink: UInt16, mode: mode_t)] {
    (0..<getdtablesize()).compactMap { descriptor in
        var status = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &status) == 0, fcntl(descriptor, F_GETPATH, &path) == 0,
              String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)?.contains(prefix) == true
        else { return nil }
        return (status.st_nlink, status.st_mode)
    }
}

@Test func spoolReturnsRecordsInTheOrderTheyWereAppended() async throws {
    try await withScratchDirectory { directory in
        let spool = try SpoolFile(directory: directory)
        let large = [UInt8]((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let records: [[UInt8]] = [[1, 2, 3], [], large, Array("last".utf8), [UInt8](repeating: 9, count: 70_000)]
        for record in records { try spool.append(record) }
        #expect(spool.byteCount == records.reduce(0) { $0 + 8 + $1.count })
        for record in records { #expect(try spool.next() == record) }
        #expect(try spool.next() == nil)
    }
}

@Test func spoolEmptiesOnceTheReaderCatchesUp() async throws {
    try await withScratchDirectory { directory in
        let spool = try SpoolFile(directory: directory)
        #expect(try spool.next() == nil)
        try spool.append(Data([7]))
        try spool.append([8, 9])
        #expect(try spool.next() == [7])
        #expect(spool.byteCount == 19)
        #expect(try spool.next() == [8, 9])
        #expect(spool.byteCount == 0)
        #expect(try spool.next() == nil)
        try spool.append([10])
        #expect(spool.byteCount == 9)
        #expect(try spool.next() == [10])
        #expect(try spool.next() == nil)
    }
}

@Test func spoolReadsWhileAnotherThreadAppends() async throws {
    try await withScratchDirectory { directory in
        let spool = try SpoolFile(directory: directory)
        let count = 2_000
        let record: @Sendable (Int) -> [UInt8] = { [UInt8](repeating: UInt8($0 % 251), count: 1 + ($0 * 37) % 90_000) }
        let appended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for index in 0..<count {
                try? spool.append(record(index))
                appended.signal()
            }
        }
        let mismatches = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var mismatches = 0
                for index in 0..<count {
                    appended.wait()
                    if (try? spool.next()) != record(index) { mismatches += 1 }
                }
                continuation.resume(returning: mismatches)
            }
        }
        #expect(mismatches == 0)
        #expect(try spool.next() == nil)
    }
}

@Test func spoolLeavesNoNameAndOnlyItsOwnerCanOpenIt() async throws {
    try await withScratchDirectory { directory in
        let prefix = "spool-test-\(UUID().uuidString)"
        var spool: SpoolFile? = try SpoolFile(directory: directory, prefix: prefix)
        try spool?.append([1])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
        let open = openFiles(prefix: prefix)
        #expect(open.count == 1)
        #expect(open.first?.nlink == 0)
        #expect((open.first?.mode ?? 0) & 0o777 == 0o600)
        spool = nil
        #expect(openFiles(prefix: prefix).isEmpty)
    }
}

@Test func spoolInAMissingDirectoryFailsToCreate() {
    let missing = FileManager.default.temporaryDirectory.appending(path: "spool-missing-\(UUID().uuidString)/inner")
    #expect(throws: SpoolFileError.cannotCreate(errno: ENOENT)) { try SpoolFile(directory: missing) }
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)).localizedDescription
    #expect(SpoolFileError.writeFailed(errno: ENOSPC).localizedDescription == posix)
}
#endif
