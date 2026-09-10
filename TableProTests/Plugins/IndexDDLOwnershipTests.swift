//
//  IndexDDLOwnershipTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A driver answers `fetchIndexDDL` or it declares its indexes inside `fetchTableDDL`. Never both,
/// or a dump creates every index twice and the restore fails on the second.
///
/// Nothing at runtime can see the contradiction: `fetchTableDDL` hands back opaque text and the
/// export writes whatever it gets. So the guard is a source scan, the same shape
/// `SyncMapperFieldAccessTests` uses to keep raw `record[` out of the sync mappers.
@Suite("Index DDL ownership")
struct IndexDDLOwnershipTests {
    private static let pluginsDirectory: URL? = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        let plugins = directory.appendingPathComponent("Plugins")
        return FileManager.default.fileExists(atPath: plugins.path) ? plugins : nil
    }()

    private static func driverSources() throws -> [(name: String, text: String)] {
        guard let pluginsDirectory else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory, includingPropertiesForKeys: nil)
        return try folders
            .filter { $0.lastPathComponent.hasSuffix("DriverPlugin") }
            .flatMap { folder -> [(String, String)] in
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil)) ?? []
                return try files
                    .filter { $0.pathExtension == "swift" }
                    .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
            }
    }

    @Test("The scan reaches the driver plugins at all")
    func sourcesAreReachable() throws {
        let sources = try Self.driverSources()
        #expect(!sources.isEmpty, "No driver plugin sources found; the guard below would pass vacuously")
        #expect(sources.contains { $0.text.contains("func fetchIndexDDL") })
    }

    @Test("No driver both answers fetchIndexDDL and writes CREATE INDEX into its table DDL")
    func noDriverDeclaresIndexesTwice() throws {
        let sources = try Self.driverSources()
        var offenders: [String] = []
        for source in sources where source.text.contains("func fetchIndexDDL") {
            guard let ddlRange = source.text.range(of: "func fetchTableDDL") else { continue }
            let body = source.text[ddlRange.lowerBound...].prefix(6_000)
            if body.contains("CREATE \\(uniqueStr)INDEX") || body.contains("\"CREATE INDEX") {
                offenders.append(source.name)
            }
        }

        #expect(offenders.isEmpty, "These drivers declare indexes in both places: \(offenders)")
    }
}
