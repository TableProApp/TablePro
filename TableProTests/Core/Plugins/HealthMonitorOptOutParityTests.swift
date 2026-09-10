//
//  HealthMonitorOptOutParityTests.swift
//  TableProTests
//
//  supportsHealthMonitor is declared twice, in the curated metadata table and on the plugin, and
//  the plugin wins: buildMetadataSnapshot reads it straight off the DriverPlugin type, so a
//  curated `false` that the plugin does not repeat is silently discarded and the app pings a
//  connection it had already decided to leave alone (#2700).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Health monitor opt-out parity")
struct HealthMonitorOptOutParityTests {
    @Test("every type curated as health-monitor-free says so on its plugin too")
    func curatedOptOutsAreDeclaredOnTheirPlugins() throws {
        let optedOut = DatabaseType.allKnownTypes.filter { type in
            PluginMetadataRegistry.shared.snapshot(for: type)?.supportsHealthMonitor == false
        }
        #expect(!optedOut.isEmpty, "The curated table opts at least SQLite and DuckDB out")

        let sources = try Self.pluginSources()
        var missing: [String] = []
        for type in optedOut {
            guard let source = sources.first(where: { $0.declaresTypeId(type.rawValue) }) else {
                missing.append("\(type.rawValue) (no plugin source declares this type id)")
                continue
            }
            if !source.text.contains("static let supportsHealthMonitor = false") {
                missing.append("\(type.rawValue) (\(source.url.lastPathComponent))")
            }
        }

        #expect(
            missing.isEmpty,
            """
            The plugin is the authoritative side: PluginMetadataRegistry.buildMetadataSnapshot copies \
            supportsHealthMonitor off the DriverPlugin type, so these keep a 30-second ping the \
            curated table already turned off: \(missing.sorted())
            """
        )
    }

    private struct PluginSource {
        let url: URL
        let text: String

        func declaresTypeId(_ id: String) -> Bool {
            text.contains("static let databaseTypeId = \"\(id)\"")
        }
    }

    private static func pluginSources(file: StaticString = #filePath) throws -> [PluginSource] {
        let root = try repositoryRoot(file: file).appendingPathComponent("Plugins")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ParityError.sourcesNotFound
        }
        var sources: [PluginSource] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("static let databaseTypeId = ")
            else { continue }
            sources.append(PluginSource(url: url, text: text))
        }
        guard !sources.isEmpty else { throw ParityError.sourcesNotFound }
        return sources
    }

    private static func repositoryRoot(file: StaticString) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Plugins/TableProPluginKit/DriverPlugin.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        throw ParityError.sourcesNotFound
    }

    private enum ParityError: Error {
        case sourcesNotFound
    }
}
