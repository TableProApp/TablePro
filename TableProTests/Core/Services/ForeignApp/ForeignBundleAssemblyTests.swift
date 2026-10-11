//
//  ForeignBundleAssemblyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

struct ForeignBundleAssemblyTests {
    private func record(
        _ name: String,
        sourceId: String?,
        groupPath: [String] = [],
        password: String? = nil
    ) -> ForeignConnectionRecord {
        ForeignConnectionRecord(
            sourceId: sourceId,
            settings: ExportableConnection(
                name: name, host: "db.example.com", port: 5_432, database: name, username: "app", type: "PostgreSQL"
            ),
            groupPath: groupPath,
            credentials: ExportableCredentials(
                password: password,
                sshPassword: nil,
                keyPassphrase: nil,
                sslClientKeyPassphrase: nil,
                totpSecret: nil,
                pluginSecureFields: nil
            )
        )
    }

    private func query(
        _ name: String,
        sql: String = "select 1;",
        connection: String? = nil,
        folderPath: [String] = [],
        keyword: String? = nil,
        isAutoNamed: Bool = false
    ) -> ForeignSavedQuery {
        ForeignSavedQuery(
            name: name,
            content: .text(sql),
            keyword: keyword,
            folderPath: folderPath,
            sourceConnectionId: connection,
            isAutoNamed: isAutoNamed
        )
    }

    private func collect(
        _ connections: [ForeignConnectionRecord],
        _ queries: [ForeignSavedQuery] = [],
        credentialsAborted: Bool = false
    ) throws -> CollectedImport {
        try ForeignBundleAssembly.collect(
            appName: "Sample App",
            connections: connections,
            savedQueries: queries,
            credentialsAborted: credentialsAborted
        )
    }

    // MARK: - Connections

    @Test("A connection's ref is its source id, a row ref without one, and unique on a repeat")
    func connectionRefs() throws {
        let result = try collect([
            record("A", sourceId: "abc"),
            record("B", sourceId: nil),
            record("C", sourceId: "abc"),
            record("D", sourceId: ""),
            record("E", sourceId: "row-1")
        ])

        #expect(result.bundle.connections.map { $0.ref } == ["abc", "row-1", "abc-2", "row-3", "row-1-4"])
    }

    @Test("Credentials are keyed by the connection's ref and empty ones are dropped")
    func credentialsFollowRefs() throws {
        let result = try collect([
            record("A", sourceId: "a", password: "secret"),
            record("B", sourceId: "b")
        ])

        #expect(result.bundle.credentials["a"]?.password == "secret")
        #expect(result.bundle.credentials["b"] == nil)
    }

    @Test("Group paths keep their nesting and repeated paths share one group")
    func groupPaths() throws {
        let result = try collect([
            record("A", sourceId: "a", groupPath: ["Client", "Prod"]),
            record("B", sourceId: "b", groupPath: ["Client", "Prod"]),
            record("C", sourceId: "c", groupPath: ["Other", "Prod"])
        ])

        #expect(result.groupPath(at: 0) == ["Client", "Prod"])
        #expect(result.groupPath(at: 2) == ["Other", "Prod"])
        #expect(result.bundle.groups.count == 4)
    }

    @Test("Source name and the aborted flag pass through")
    func sourceAndAbortFlag() throws {
        let result = try collect([record("A", sourceId: "a")], credentialsAborted: true)

        #expect(result.source == .foreignApp(name: "Sample App"))
        #expect(result.credentialsAborted)
        #expect(result.bundle.appVersion == "Sample App Import")
    }

    @Test("Nothing to import throws noConnectionsFound")
    func emptyThrows() {
        #expect(throws: ForeignAppImportError.self) {
            try collect([])
        }
    }

    // MARK: - Saved Queries

    @Test("A global query lands in a root folder named after the app")
    func globalQueryUnderAppFolder() throws {
        let result = try collect(
            [record("A", sourceId: "a")],
            [query("Locks", folderPath: ["Ops", "Daily"], keyword: "lk")]
        )

        let locks = try #require(result.savedQuery(named: "Locks"))
        #expect(locks.connectionRef == nil)
        #expect(locks.keyword == "lk")
        #expect(result.folderPath(of: locks) == ["Sample App", "Ops", "Daily"])
        #expect(result.isSuggested(locks))
    }

    @Test("A query bound to an imported connection keeps that scope, folders included")
    func boundQueryKeepsScope() throws {
        let result = try collect(
            [record("A", sourceId: "a")],
            [query("Report", connection: "a", folderPath: ["Reports"])]
        )

        let report = try #require(result.savedQuery(named: "Report"))
        #expect(report.connectionRef == "a")
        #expect(result.folderPath(of: report) == ["Reports"])
        #expect(result.bundle.folderChain(report.folderRef).allSatisfy { $0.connectionRef == "a" })
        #expect(result.isSuggested(report))
    }

    @Test("A query bound to a connection that is not imported lands global and unchecked")
    func unmappedQueryIsGlobalAndUnsuggested() throws {
        let result = try collect(
            [record("A", sourceId: "a")],
            [query("Orphan", connection: "missing", folderPath: ["Sub"])]
        )

        let orphan = try #require(result.savedQuery(named: "Orphan"))
        #expect(orphan.connectionRef == nil)
        #expect(result.folderPath(of: orphan) == ["Sample App", "Sub"])
        #expect(!result.isSuggested(orphan))
    }

    @Test("An auto-named query is listed unchecked")
    func autoNamedQueryIsUnsuggested() throws {
        let result = try collect(
            [record("A", sourceId: "a")],
            [query("console", connection: "a", isAutoNamed: true), query("Named", connection: "a")]
        )

        let console = try #require(result.savedQuery(named: "console"))
        let named = try #require(result.savedQuery(named: "Named"))
        #expect(!result.isSuggested(console))
        #expect(result.isSuggested(named))
    }

    @Test("An oversized query is listed outside the bundle with a ref that never collides")
    func oversizedRefsShareTheNamespace() throws {
        let oversized = ForeignSavedQuery(
            name: "Huge",
            content: .oversized(byteCount: 2_000_000),
            keyword: nil,
            folderPath: ["Big"],
            sourceConnectionId: "a",
            isAutoNamed: false
        )
        let result = try collect(
            [record("A", sourceId: "a")],
            [query("First", connection: "a"), oversized, query("Second")]
        )

        #expect(result.savedQuery(named: "Huge") == nil)
        let huge = try #require(result.oversizedQueries.first)
        #expect(huge.name == "Huge")
        #expect(huge.byteCount == 2_000_000)
        #expect(huge.connection == "a")
        #expect(huge.folderPath == ["Big"])

        let refs = result.bundle.savedQueries.map { $0.ref } + result.oversizedQueries.map { $0.ref }
        #expect(Set(refs).count == 3)
    }

    @Test("Saved queries import even when the app has no connections")
    func queriesWithoutConnections() throws {
        let result = try collect([], [query("Locks")])

        #expect(result.bundle.connections.isEmpty)
        #expect(result.savedQueryNames == ["Locks"])
    }
}
