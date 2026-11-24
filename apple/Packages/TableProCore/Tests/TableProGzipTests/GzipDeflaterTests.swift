import Foundation
import TableProGzip
import TableProWireIO
import Testing

private enum DeflaterFixture {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func dumpText(lines: Int) -> Data {
        Data((0..<lines).map { "INSERT INTO t VALUES (\($0), 'row \($0)');\n" }.joined().utf8)
    }

    static let gzipPath = "/usr/bin/gzip"

    static func gunzip(_ source: URL, to destination: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzipPath)
        process.arguments = ["-dc", source.path(percentEncoded: false)]
        // Apple's gzip reads extra options from GZIP.
        process.environment = [:]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

@Test("Compressed data inflates back to itself", arguments: [0, 1, 4_096, 3 << 20])
func deflatedDataRoundTrips(count: Int) throws {
    let input = DeflaterFixture.dumpText(lines: count / 40 + 1).prefix(count)
    let packed = try GzipDeflater.compress(Data(input))
    #expect(packed.prefix(2) == Data([0x1F, 0x8B]))
    #expect(try GzipInflater.decompress(packed, budget: .init(limit: .max, ratioLimit: .max, grace: .max)) == Data(input))
}

@Test("Bytes that do not compress still round trip")
func incompressibleBytesRoundTrip() throws {
    let input = DeflaterFixture.randomBytes(1 << 20)
    let packed = try GzipDeflater.compress(input)
    #expect(try GzipInflater.decompress(packed) == input)
}

@Test("A compressed file larger than one read chunk inflates back to its source")
func compressedFileRoundTrips() throws {
    let directory = try DeflaterFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("dump.sql")
    let input = DeflaterFixture.dumpText(lines: 60_000) + DeflaterFixture.randomBytes(300_000)
    #expect(input.count > 1 << 20)
    try input.write(to: source)
    let destination = directory.appendingPathComponent("dump.sql.gz")

    var reported: [(Int64, Int64)] = []
    try GzipFile.compress(source: source, to: destination, isCancelled: { false }) { reported.append(($0, $1)) }

    #expect(try GzipInflater.decompress(Data(contentsOf: destination)) == input)
    #expect(reported.first.map { $0.0 == 0 } == true)
    #expect(reported.last.map { $0.0 == Int64(input.count) && $0.1 == Int64(input.count) } == true)
}

@Test(
    "gzip -d reads what the deflater writes",
    .enabled(if: FileManager.default.isExecutableFile(atPath: DeflaterFixture.gzipPath)),
    arguments: [0, 5_000, 2 << 20]
)
func systemGzipReadsTheOutput(count: Int) throws {
    let directory = try DeflaterFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("dump.sql")
    let input = Data((DeflaterFixture.dumpText(lines: count / 40 + 1) + DeflaterFixture.randomBytes(count / 4)).prefix(count))
    try input.write(to: source)
    let packed = directory.appendingPathComponent("dump.sql.gz")
    try GzipFile.compress(source: source, to: packed, isCancelled: { false })
    let unpacked = directory.appendingPathComponent("unpacked.sql")

    #expect(try DeflaterFixture.gunzip(packed, to: unpacked) == 0)
    #expect(try Data(contentsOf: unpacked) == input)
}

@Test("A stop partway through a file throws and leaves nothing at the destination")
func cancellationLeavesNoPartialFile() throws {
    let directory = try DeflaterFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("dump.sql")
    try DeflaterFixture.randomBytes(3 << 20).write(to: source)
    let destination = directory.appendingPathComponent("dump.sql.gz")

    var checks = 0
    #expect(throws: CancellationError.self) {
        try GzipFile.compress(source: source, to: destination, isCancelled: {
            checks += 1
            return checks > 2
        })
    }
    #expect(checks == 3)
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
}

@Test("A stop before the trailer is written throws rather than leaving a cut stream")
func cancellationAfterTheLastChunkThrows() throws {
    let directory = try DeflaterFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("dump.sql")
    try DeflaterFixture.dumpText(lines: 10).write(to: source)
    let destination = directory.appendingPathComponent("dump.sql.gz")

    var checks = 0
    #expect(throws: CancellationError.self) {
        try GzipFile.compress(source: source, to: destination, isCancelled: {
            checks += 1
            return checks > 1
        })
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
}
