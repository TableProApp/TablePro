//
//  CompareCapabilityDeclarationTests.swift
//  TableProTests
//
//  Compare & Sync is gated on `.schemaCompare` and `.dataCompare`, and both bits shipped for two
//  releases with no driver setting either, so the feature refused every connection it was offered.
//  A driver lives in a plugin bundle the test target cannot import, so the declaration is checked by
//  reading the driver's source.
//

import Foundation
import Testing

@Suite("Compare capability declaration")
struct CompareCapabilityDeclarationTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static let bundledSQLDriverSources = [
        "Plugins/MySQLDriverPlugin/MySQLPluginDriver.swift",
        "Plugins/PostgreSQLDriverPlugin/PostgreSQLPluginDriver.swift",
        "Plugins/SQLiteDriverPlugin/SQLitePlugin.swift",
    ]

    private func capabilitiesDeclaration(in source: String) -> String? {
        guard let start = source.range(of: "var capabilities: PluginCapabilities") else { return nil }
        let body = source[start.upperBound...]
        guard let end = body.range(of: "\n    }") else { return nil }
        return String(body[..<end.lowerBound])
    }

    @Test("Every bundled SQL driver declares both compare capabilities")
    func bundledSQLDriversDeclareCompareCapabilities() throws {
        for path in Self.bundledSQLDriverSources {
            let url = Self.repositoryRoot.appendingPathComponent(path)
            let source = try String(contentsOf: url, encoding: .utf8)
            let declaration = capabilitiesDeclaration(in: source)
            let capabilities = try #require(
                declaration,
                "\(path) no longer declares var capabilities: PluginCapabilities"
            )

            #expect(
                capabilities.contains(".schemaCompare"),
                "\(path) must declare .schemaCompare, or Compare & Sync refuses every structure comparison"
            )
            #expect(
                capabilities.contains(".dataCompare"),
                "\(path) must declare .dataCompare, or Compare & Sync refuses every data comparison"
            )
        }
    }
}
