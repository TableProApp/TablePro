import Foundation
import TableProGzip
import TableProWireIO
import Testing
import zlib

enum GzipFixture {
    static func gzip(repeating byte: UInt8, count: Int) -> Data {
        var stream = z_stream()
        let status = deflateInit2_(
            &stream, Z_BEST_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 9, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        precondition(status == Z_OK, "deflateInit2_ failed")
        defer { deflateEnd(&stream) }
        var input = [UInt8](repeating: byte, count: min(count, 1 << 20))
        var output = [UInt8](repeating: 0, count: 1 << 20)
        var result = Data()
        var left = count
        repeat {
            let take = min(left, input.count)
            left -= take
            let flush = left == 0 ? Z_FINISH : Z_NO_FLUSH
            input.withUnsafeMutableBufferPointer { source in
                stream.next_in = source.baseAddress
                stream.avail_in = uInt(take)
                repeat {
                    output.withUnsafeMutableBufferPointer { target in
                        stream.next_out = target.baseAddress
                        stream.avail_out = uInt(target.count)
                        deflate(&stream, flush)
                        guard let base = target.baseAddress else { return }
                        result.append(base, count: target.count - Int(stream.avail_out))
                    }
                } while stream.avail_out == 0
            }
        } while left > 0
        return result
    }

    static func gzip(_ text: String) -> Data {
        var stream = z_stream()
        _ = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        defer { deflateEnd(&stream) }
        var input = Array(text.utf8)
        var output = [UInt8](repeating: 0, count: input.count + 1_024)
        input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress
                stream.avail_in = uInt(source.count)
                stream.next_out = target.baseAddress
                stream.avail_out = uInt(target.count)
                deflate(&stream, Z_FINISH)
            }
        }
        return Data(output.prefix(Int(stream.total_out)))
    }
}

@Test func inflatesOneMember() throws {
    let text = String(repeating: "id,name\n1,alice\n", count: 500)
    let output = try GzipInflater.decompress(GzipFixture.gzip(text))
    #expect(String(bytes: output, encoding: .utf8) == text)
}

@Test func inflatesEveryConcatenatedMember() throws {
    let output = try GzipInflater.decompress(GzipFixture.gzip("first\n") + GzipFixture.gzip("second\n"))
    #expect(String(bytes: output, encoding: .utf8) == "first\nsecond\n")
}

@Test func ignoresPaddingAfterTheLastMember() throws {
    let output = try GzipInflater.decompress(GzipFixture.gzip("rows\n") + Data(repeating: 0, count: 512))
    #expect(String(bytes: output, encoding: .utf8) == "rows\n")
}

@Test func refusesTruncatedInput() throws {
    let whole = GzipFixture.gzip(String(repeating: "abcdefgh", count: 4_000))
    #expect(throws: GzipError.truncated) {
        try GzipInflater.decompress(whole.prefix(whole.count / 2))
    }
}

@Test func refusesCorruptInput() throws {
    var bytes = [UInt8](GzipFixture.gzip(String(repeating: "abcdefgh", count: 4_000)))
    for index in 20..<40 { bytes[index] ^= 0xFF }
    #expect(throws: GzipError.corrupt) {
        try GzipInflater.decompress(Data(bytes))
    }
}

@Test func stopsAtTheBudgetLimit() throws {
    let bomb = GzipFixture.gzip(repeating: 0, count: 8 << 20)
    let budget = DecompressionBudget(limit: 1 << 20, ratioLimit: .max, grace: 0)
    var produced = 0
    #expect(throws: GzipError.expandsTooFar) {
        try GzipInflater.decompress(bomb, budget: budget) { produced += $0.count }
    }
    #expect(produced <= 1 << 20)
}

// 80 MiB of empty lines packs into about 80 KB, past the ratio a reply decoded in memory may reach.
@Test func inMemoryDecodingRefusesPastTheExpansionRatio() {
    let packed = GzipFixture.gzip(repeating: 0x0A, count: 80 << 20)
    var produced = 0
    #expect(throws: GzipError.expandsTooFar) {
        try GzipInflater.decompress(packed) { produced += $0.count }
    }
    #expect(produced < 80 << 20)
}

// A dump of zero-filled BLOBs or a one-hot CSV packs as far, and a file on disk keeps to no ratio.
@Test func decompressesAFilePastTheExpansionRatio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("export.csv.gz")
    try GzipFixture.gzip(repeating: 0x0A, count: 80 << 20).write(to: source)
    let destination = directory.appendingPathComponent("export.csv")

    try await GzipFile.decompress(source: source, destination: destination, outputLimit: 1 << 30)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))
    #expect(attributes[.size] as? Int == 80 << 20)
}

@Test func refusesAFilePastItsOutputLimitAndLeavesNothing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("dump.sql.gz")
    try GzipFixture.gzip(repeating: 0, count: 8 << 20).write(to: source)
    let destination = directory.appendingPathComponent("dump.sql")

    await #expect(throws: GzipError.needsMoreDiskSpace) {
        try await GzipFile.decompress(source: source, destination: destination, outputLimit: 1 << 20)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
}

@Test func fileBudgetLeavesTheReserveFreeWithNoRatio() throws {
    let twentyGigabytes = 20 << 30
    var budget = GzipFile.budget(availableSpace: twentyGigabytes)
    #expect(budget.limit == twentyGigabytes - GzipFile.reservedSpace)
    #expect(GzipFile.budget(availableSpace: GzipFile.reservedSpace / 2).limit == GzipFile.reservedSpace / 4)
    #expect(GzipFile.budget(availableSpace: 0).limit == 0)
    #expect(GzipFile.budget(availableSpace: nil).limit == .max)
    // A dump that expands to 12 GB on a volume with 20 GB free is read whole, at any ratio.
    try budget.record(produced: 12 << 30, consumed: 1)
}

@Test func decompressesAFileUnderTheRatio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = (0..<20_000).map { "\($0),row \($0)\n" }.joined()
    let source = directory.appendingPathComponent("dump.sql.gz")
    try GzipFixture.gzip(text).write(to: source)
    let destination = directory.appendingPathComponent("dump.sql")

    try await GzipFile.decompress(source: source, destination: destination, outputLimit: 1 << 30)
    #expect(try String(contentsOf: destination, encoding: .utf8) == text)
}

@Test func removesThePartialFileWhenTheSourceIsCut() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let whole = GzipFixture.gzip((0..<20_000).map { "\($0)\n" }.joined())
    let source = directory.appendingPathComponent("cut.sql.gz")
    try whole.prefix(whole.count - 100).write(to: source)
    let destination = directory.appendingPathComponent("cut.sql")

    await #expect(throws: GzipError.truncated) {
        try await GzipFile.decompress(source: source, destination: destination, outputLimit: 1 << 30)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
}
