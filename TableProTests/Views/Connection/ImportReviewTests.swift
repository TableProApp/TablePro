//
//  ImportReviewTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct ImportReviewTests {
    private static let orders = ExportableConnection(
        name: "Orders", host: "db.example.com", port: 3_306, database: "orders", username: "app", type: "MySQL"
    )
    private static let tunnel = ExportableTunnelCommand(
        method: "custom",
        command: "ssh -N -L {port}:db.internal:3306 bastion",
        executablePath: nil,
        kubernetesNamespace: nil,
        kubernetesResource: nil,
        kubernetesContext: nil,
        awsTarget: nil,
        awsProfile: nil,
        awsRegion: nil
    )

    @Test("The saved query header leaves out rows that cannot be imported")
    func queryTogglesSkipDisabledRows() throws {
        let review = try makeReview(library: [Self.entry("Locks", "SELECT 2", scope: nil)])

        #expect(review.preview.queries.count == 2)
        #expect(review.queryToggles.count == 1)
        #expect(review.connectionToggles.count == 1)

        let connectionToggle = try #require(review.connectionToggles.first)
        connectionToggle.wrappedValue = false
        let daily = try #require(query("q1", in: review))

        #expect(review.queryToggles.isEmpty)
        #expect(review.status(of: daily)?.availability == .connectionSkipped)
    }

    @Test("Setting the header sets every available query and nothing else")
    func headerSetsAvailableQueries() throws {
        let review = try makeReview(library: [Self.entry("Locks", "SELECT 2", scope: nil)])

        for toggle in review.queryToggles {
            toggle.wrappedValue = false
        }
        #expect(review.plan.queries.isEmpty)
        #expect(review.includedQueryCount == 0)

        for toggle in review.queryToggles {
            toggle.wrappedValue = true
        }
        let locks = try #require(query("q2", in: review))
        #expect(plannedRefs(review) == ["q1"])
        #expect(review.status(of: locks)?.availability == .alreadySaved)
    }

    @Test("The plan follows every change to the selection")
    func planFollowsSelection() throws {
        let review = try makeReview()
        let daily = try #require(query("q1", in: review))
        #expect(review.plan.connections.count == 1)
        #expect(review.plan.queries.count == 2)

        review.setIncluded(false, daily)
        #expect(plannedRefs(review) == ["q2"])

        let row = try #require(review.preview.connections.first)
        review.setSelected(false, row)
        #expect(review.plan.connections.isEmpty)
        #expect(plannedRefs(review) == ["q2"])
        #expect(review.selectedConnectionCount == 0)
    }

    @Test("Only selected rows that write settings ask about their tunnel command")
    func tunnelRowsFollowSelection() throws {
        var settings = Self.orders
        settings.tunnelCommand = Self.tunnel
        let review = try makeReview(settings: settings)
        let row = try #require(review.preview.connections.first)

        #expect(tunnelRefs(review) == [row.ref])

        review.setSelected(false, row)
        #expect(review.rowsWithCommands.isEmpty)
    }

    @Test("Startup SQL is asked about like a tunnel command, and stripped unless kept")
    func startupCommandsNeedTheSameAnswer() async throws {
        var settings = Self.orders
        settings.startupCommands = "SET search_path TO app;"
        let store = RecordingLibraryStore()
        let review = try makeReview(settings: settings, store: store)
        let row = try #require(review.preview.connections.first)

        #expect(tunnelRefs(review) == [row.ref])

        _ = await review.commit(keepingCommands: false)
        #expect(store.written.first?.planned.settings.startupCommands == nil)
    }

    @Test("Keep Existing writes no settings, so its tunnel command is not asked about")
    func keepExistingSkipsTunnelQuestion() throws {
        var settings = Self.orders
        settings.tunnelCommand = Self.tunnel
        let existingId = UUID()
        let review = try makeReview(settings: settings, existing: existingId)
        let row = try #require(review.preview.connections.first)

        review.setSelected(true, row)
        #expect(review.resolution(for: row) == .keepExisting(existingId))
        #expect(review.rowsWithCommands.isEmpty)

        review.setResolution(.addCopy, for: row)
        #expect(tunnelRefs(review) == [row.ref])
    }

    @Test("Import strips the tunnel command unless the user keeps it")
    func commitAppliesTheTunnelAnswer() async throws {
        var settings = Self.orders
        settings.tunnelCommand = Self.tunnel

        let stripping = RecordingLibraryStore()
        let stripped = try makeReview(settings: settings, store: stripping)
        let strippedOutcome = await stripped.commit(keepingCommands: false)
        #expect(strippedOutcome.connectionsAdded == 1)
        #expect(stripping.written.first?.planned.settings.tunnelCommand == nil)

        let keeping = RecordingLibraryStore()
        let kept = try makeReview(settings: settings, store: keeping)
        _ = await kept.commit(keepingCommands: true)
        #expect(keeping.written.first?.planned.settings.tunnelCommand == Self.tunnel)
    }

    @Test("Import hands the included saved queries to the saved query store")
    func commitImportsIncludedQueries() async throws {
        let queries = RecordingSavedQueryStore()
        let review = try makeReview(savedQueries: queries)
        let locks = try #require(query("q2", in: review))
        review.setIncluded(false, locks)

        let outcome = await review.commit(keepingCommands: false)
        let received = await queries.received.map { $0.ref }

        #expect(received == ["q1"])
        #expect(outcome.savedQueriesAdded == 1)
        #expect(!review.isImporting)
    }

    @Test("Unchecking the saved query header also reaches a row another selected row adds")
    func headerReachesRowsAddedByAnotherRow() throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(Self.orders, ref: "c1")
        var twin = Self.orders
        twin.name = "Orders twin"
        builder.addConnection(twin, ref: "c2")
        builder.addSavedQuery(name: "Locks", sql: "SELECT 2", keyword: nil, connection: "c1", ref: "q1")
        builder.addSavedQuery(name: "Locks", sql: "SELECT 2", keyword: nil, connection: "c2", ref: "q2")
        let collected = CollectedImport(bundle: try builder.build(), source: .file(name: "Tests.tablepro"))
        let existing = ImportLibrarySnapshot.Connection(id: UUID(), name: "Orders", matchKey: ConnectionMatchKey(Self.orders))
        let preview = ConnectionImportAnalyzer.analyze(
            collected,
            library: ImportLibrarySnapshot(connections: [existing]),
            environment: ImportEnvironment(
                rules: ImportRules(maximumGroupDepth: 3, supportsSavedQueries: true, supportsCredentialProfiles: true),
                registeredTypeIds: ["MySQL"],
                fileExists: { _ in true }
            )
        )
        let review = ImportReview(preview: preview, library: RecordingLibraryStore(), savedQueries: nil)
        for row in preview.connections {
            review.setSelected(true, row)
        }
        let held = try #require(query("q2", in: review))
        #expect(review.status(of: held)?.availability == .addedByAnotherRow)
        #expect(review.queryToggles.count == 2)

        for toggle in review.queryToggles {
            toggle.wrappedValue = false
        }

        #expect(review.plan.queries.isEmpty)
    }

    private func makeReview(
        settings: ExportableConnection = ImportReviewTests.orders,
        existing: UUID? = nil,
        library: [SavedQueryLedger.Entry] = [],
        store: RecordingLibraryStore = RecordingLibraryStore(),
        savedQueries: RecordingSavedQueryStore? = nil
    ) throws -> ImportReview {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings, ref: "c1")
        builder.addSavedQuery(name: "Daily orders", sql: "SELECT 1", keyword: nil, connection: "c1", ref: "q1")
        builder.addSavedQuery(name: "Locks", sql: "SELECT 2", keyword: nil, connection: nil, ref: "q2")
        let collected = CollectedImport(bundle: try builder.build(), source: .file(name: "Tests.tablepro"))

        let connections = existing.map {
            [ImportLibrarySnapshot.Connection(id: $0, name: "Orders", matchKey: ConnectionMatchKey(settings))]
        } ?? []
        let environment = ImportEnvironment(
            rules: ImportRules(maximumGroupDepth: 3, supportsSavedQueries: true, supportsCredentialProfiles: true),
            registeredTypeIds: ["MySQL"],
            fileExists: { _ in true }
        )
        let preview = ConnectionImportAnalyzer.analyze(
            collected,
            library: ImportLibrarySnapshot(connections: connections, savedQueries: library),
            environment: environment
        )
        return ImportReview(preview: preview, library: store, savedQueries: savedQueries ?? RecordingSavedQueryStore())
    }

    private func query(_ ref: BundleRef, in review: ImportReview) -> QueryRow? {
        review.preview.queries.first { $0.ref == ref }
    }

    private func plannedRefs(_ review: ImportReview) -> [BundleRef] {
        review.plan.queries.map { $0.ref }
    }

    private func tunnelRefs(_ review: ImportReview) -> [BundleRef] {
        review.rowsWithCommands.map { $0.ref }
    }

    private static func entry(_ name: String, _ sql: String, scope: UUID?) -> SavedQueryLedger.Entry {
        SavedQueryLedger.Entry(name: name, sql: sql, keyword: nil, connectionId: scope)
    }
}

@MainActor
private final class RecordingLibraryStore: ImportLibraryStore {
    private(set) var written: [ResolvedConnection] = []

    func snapshot() async throws -> ImportLibrarySnapshot {
        ImportLibrarySnapshot()
    }

    func addImportedProfiles(_ profiles: [PlannedCredentialProfile]) throws -> [BundleRef: UUID] {
        [:]
    }

    func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] {
        paths.map { _ in nil }
    }

    func ensureTags(_ tags: [PlannedTag]) throws -> [String: UUID] {
        [:]
    }

    func writeConnections(_ connections: [ResolvedConnection]) -> ConnectionImportWrite? {
        written = connections
        return ConnectionImportWrite(
            added: connections.filter { $0.planned.write == .add }.map(\.planned.id),
            replaced: connections.filter { $0.planned.write == .replace }.map(\.planned.id)
        )
    }

    func existingConnectionIds() -> Set<UUID> {
        Set(written.map(\.planned.id))
    }

    func writeCredentials(_ credentials: ExportableCredentials, connectionId: UUID) {}
}

private actor RecordingSavedQueryStore: SavedQueryImportStore {
    private(set) var received: [PlannedQuery] = []

    func importSavedQueries(_ queries: [PlannedQuery]) async -> SavedQueryImportWrite? {
        received = queries
        return SavedQueryImportWrite(
            insertedIds: queries.map { _ in UUID() },
            createdFolderIds: [],
            alreadySaved: 0,
            droppedKeywords: 0,
            tooLarge: 0
        )
    }
}
