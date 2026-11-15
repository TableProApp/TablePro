import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SurfaceStubDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        "DROP \(objectType) \(name)"
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["TRUNCATE \(table)"]
    }
}

// A member the adapter declares with a different type than the protocol's would not witness it, and every call
// through `DatabaseDriver` would take the default instead.
@MainActor
struct DatabaseDriverPluginSurfaceTests {
    @Test("Through the protocol, the adapter answers with its plugin, its timeout and its statements")
    func adapterWitnessesTheSurface() async throws {
        let plugin = SurfaceStubDriver()
        let driver: any DatabaseDriver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: plugin,
            effectiveQueryTimeoutSeconds: 42
        )

        #expect(driver.plugin === plugin)
        #expect(driver.sessionQueryTimeoutSeconds == 42)
        #expect(driver.dropObjectStatement(name: "t", objectType: "TABLE", schema: nil, cascade: false) == "DROP TABLE t")
        #expect(driver.truncateTableStatements(table: "t", schema: nil, cascade: false) == ["TRUNCATE t"])
        for try await _ in driver.streamRows(query: "SELECT 1", safeModeIsReadOnly: false) {}
    }

    @Test("A driver that wraps no plugin has no plugin, no session timeout and no table statements")
    func driverWithoutAPluginAnswersNothing() async {
        let driver: any DatabaseDriver = MockDatabaseDriver()
        let ref = TestFixtures.makeTableRef(name: "t")

        #expect(driver.plugin == nil)
        #expect(driver.sessionQueryTimeoutSeconds == nil)
        #expect(driver.dropObjectStatement(name: "t", objectType: "TABLE", schema: nil, cascade: false) == nil)
        #expect(driver.tableOperationEligibility(for: [ref], isReadOnly: false).droppable.isEmpty)
        await #expect(throws: DatabaseError.self) {
            for try await _ in driver.streamRows(query: "SELECT 1", safeModeIsReadOnly: false) {}
        }
    }
}
