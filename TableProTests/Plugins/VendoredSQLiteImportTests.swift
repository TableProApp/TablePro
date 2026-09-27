//
//  VendoredSQLiteImportTests.swift
//  TableProTests
//
//  A plugin that links its own SQLite compiled one file against the SDK's `SQLite3` module, whose
//  `link "sqlite3"` puts macOS's library on that plugin's link line beside the vendored one.
//

import Foundation
import Testing

struct VendoredSQLiteImportTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// The source directories of every target `project.yml` force-loads the vendored library into:
    /// the plugin's own folder and each TableProCore product it links, read from the manifest so a
    /// new target on that library is covered the moment it is added.
    private static func vendoredSourceDirectories() throws -> [URL] {
        let manifest = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        return targetBlocks(in: manifest)
            .filter { $0.contains("libsqlite3_vendored.a") }
            .flatMap { block in
                values(of: "folder", in: block).map { repositoryRoot.appendingPathComponent("Plugins/\($0)") }
                    + values(of: "product", in: block).map {
                        repositoryRoot.appendingPathComponent("Packages/TableProCore/Sources/\($0)")
                    }
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func targetBlocks(in manifest: String) -> [String] {
        var blocks: [[Substring]] = []
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.range(of: #"^  [A-Za-z][A-Za-z0-9]*:\s*$"#, options: .regularExpression) != nil {
                blocks.append([])
            }
            if !blocks.isEmpty {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.map { $0.joined(separator: "\n") }
    }

    private static func values(of key: String, in block: String) -> [String] {
        block.split(separator: "\n").compactMap { line -> String? in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                trimmed = String(trimmed.dropFirst(2))
            }
            guard trimmed.hasPrefix("\(key):") else { return nil }
            return trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func swiftSources(in directories: [URL]) throws -> [(path: String, text: String)] {
        try directories.flatMap { directory -> [(path: String, text: String)] in
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                return []
            }
            return try enumerator.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    @Test("The scan finds both plugins that link their own SQLite, and the package they share")
    func scanReachesTheVendoredTargets() throws {
        let names = try Self.vendoredSourceDirectories().map(\.lastPathComponent)

        #expect(names.contains("SQLiteDriverPlugin"))
        #expect(names.contains("LibSQLDriverPlugin"))
        #expect(names.contains("TableProSQLiteCore"))
    }

    @Test("No source compiled into a plugin on the vendored SQLite imports the SDK's SQLite3 module")
    func noVendoredTargetImportsTheSystemModule() throws {
        let sources = try Self.swiftSources(in: Self.vendoredSourceDirectories())
        let offenders = sources
            .filter { $0.text.range(of: #"(?m)^\s*(@\w+\s+)*import\s+SQLite3\b"#, options: .regularExpression) != nil }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }

        #expect(sources.count > 10, "The plugin sources were not found; the guard below would pass vacuously")
        #expect(offenders.isEmpty, "These files import the SDK's SQLite3 instead of CSQLite: \(offenders)")
    }
}
