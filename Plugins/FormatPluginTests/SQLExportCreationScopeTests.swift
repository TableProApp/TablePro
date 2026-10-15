//
//  SQLExportCreationScopeTests.swift
//  FormatPluginTests
//
//  MySQL stores the creating session's sql_mode with each routine, trigger and event, so the dump recreates each
//  one under its own mode and then puts the dump's mode back.
//

import Foundation
import TableProPluginKit
import Testing

struct SQLExportCreationScopeTests {
    private struct InjectedFailure: Error {}

    private static let opening = ["SET @saved_sql_mode = @@sql_mode", "SET sql_mode = 'STRICT_TRANS_TABLES'"]
    private static let closing = ["SET sql_mode = @saved_sql_mode"]

    private final class DefinitionDataSource: PluginExportDataSource, @unchecked Sendable {
        let databaseTypeId = "MySQL"
        private let definitions: [String: String]
        private let failingScopes: Set<String>

        private let lock = NSLock()
        private var askedNames: [String] = []

        init(definitions: [String: String], failingScopes: Set<String> = []) {
            self.definitions = definitions
            self.failingScopes = failingScopes
        }

        var scopeRequests: [String] { lock.withLock { askedNames } }

        func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
            definitions[object.name] ?? ""
        }

        func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope? {
            lock.withLock { askedNames.append(object.name) }
            if failingScopes.contains(object.name) { throw InjectedFailure() }
            return PluginStatementScope(opening: SQLExportCreationScopeTests.opening, closing: SQLExportCreationScopeTests.closing)
        }

        func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

        func execute(query: String) async throws -> PluginQueryResult {
            PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }

        func quoteIdentifier(_ identifier: String) -> String {
            "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        }

        func escapeStringLiteral(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    }

    private func object(_ name: String, kind: PluginExportObjectKind, parentTable: String? = nil) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: "",
            tableType: kind.rawValue,
            optionValues: [true, false, false],
            schema: nil,
            kind: kind,
            parentTable: parentTable)
    }

    /// The kit's default script text ends each statement with a `;`, and a MySQL dump ends it with a line break.
    private func wrapped(_ ddl: String) -> String {
        (Self.opening + [ddl] + Self.closing).map { "\($0);\n" }.joined()
    }

    @Test("A routine, trigger and event are each written between the settings they were created with")
    func definitionsAreWrapped() async throws {
        let definitions = [
            "p": "CREATE PROCEDURE `p`() SELECT 1",
            "t": "CREATE TRIGGER `t` BEFORE INSERT ON `orders` FOR EACH ROW SET NEW.n = 1",
            "e": "CREATE EVENT `e` ON SCHEDULE EVERY 1 DAY DO DELETE FROM `orders`",
            "v": "CREATE VIEW `v` AS SELECT 1",
        ]
        let source = DefinitionDataSource(definitions: definitions)
        let output = try await SQLExportHarness.shared.dump(
            tables: [
                object("p", kind: .routine),
                object("t", kind: .trigger, parentTable: "orders"),
                object("e", kind: .event),
                object("v", kind: .view),
            ],
            dataSource: source)

        for name in ["p", "t", "e"] {
            let ddl = try #require(definitions[name])
            #expect(output.text.contains(wrapped(ddl)), "\(name)")
        }
        #expect(output.text.contains("\nCREATE VIEW `v` AS SELECT 1;\n"))
        #expect(!output.text.contains("'STRICT_TRANS_TABLES';\nCREATE VIEW"))
        #expect(Set(source.scopeRequests) == ["p", "t", "e"])
        #expect(output.result.warnings.isEmpty)
    }

    /// The second routine passes the cap. Written as separate statements, its opening settings fit in the first part
    /// and its definition rotated into the second, which then ran under the dump's mode with nothing to put back.
    @Test("A part rotation never separates a definition from its settings")
    func rotationKeepsTheWrapInOnePart() async throws {
        let big = "CREATE PROCEDURE `a_big`() SELECT '\(String(repeating: "x", count: 900 * 1_024))'"
        let small = "CREATE PROCEDURE `b_small`() SELECT '\(String(repeating: "y", count: 200 * 1_024))'"
        let source = DefinitionDataSource(definitions: ["a_big": big, "b_small": small])
        var options = SQLExportOptions()
        options.splitSizeMegabytes = 1
        options.excludeDefiner = false
        options.excludeAutoIncrementValue = false

        let output = try await SQLExportHarness.shared.dumpParts(
            tables: [object("a_big", kind: .routine), object("b_small", kind: .routine)],
            dataSource: source,
            options: options)

        #expect(output.parts.count == 2)
        for (index, part) in output.parts.enumerated() {
            let openings = part.components(separatedBy: "SET @saved_sql_mode = @@sql_mode;").count - 1
            let closings = part.components(separatedBy: "SET sql_mode = @saved_sql_mode;").count - 1
            #expect(openings == 1, "part \(index + 1)")
            #expect(closings == 1, "part \(index + 1)")
        }
        let secondPart = try #require(output.parts.last)
        #expect(secondPart.contains(wrapped(small)))
    }

    @Test("Settings that cannot be read still write the definition, and the summary names the object")
    func failedFetchWritesTheDefinitionAlone() async throws {
        let definitions = [
            "p": "CREATE PROCEDURE `p`() SELECT 1",
            "q": "CREATE PROCEDURE `q`() SELECT 2",
        ]
        let source = DefinitionDataSource(definitions: definitions, failingScopes: ["p"])
        let output = try await SQLExportHarness.shared.dump(
            tables: [object("p", kind: .routine), object("q", kind: .routine)],
            dataSource: source)

        #expect(output.text.contains("\nCREATE PROCEDURE `p`() SELECT 1;\n"))
        #expect(!output.text.contains(wrapped("CREATE PROCEDURE `p`() SELECT 1")))
        #expect(output.text.contains(wrapped("CREATE PROCEDURE `q`() SELECT 2")))
        #expect(output.result.warnings.count == 1)
        let warning = try #require(output.result.warnings.first)
        #expect(warning.contains("Could not read the settings p was created with"))
    }
}
