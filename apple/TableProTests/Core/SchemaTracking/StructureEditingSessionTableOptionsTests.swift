//
//  StructureEditingSessionTableOptionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureEditingSessionTableOptionsTests {
    private static let latin = TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", autoIncrement: 4)

    private static let catalog = TableOptionsCatalog(
        characterSets: [TableCharacterSet(
            name: "utf8mb4", defaultCollation: "utf8mb4_0900_ai_ci", collations: ["utf8mb4_0900_ai_ci"], description: nil
        )],
        engines: ["InnoDB"],
        defaultEngine: "InnoDB"
    )

    private func makeSession() -> StructureEditingSession {
        StructureEditingSession(
            identity: "shop.t",
            connection: TestFixtures.makeConnection(database: "shop", type: .mysql),
            databaseName: "shop",
            schemaName: nil,
            tableName: "t"
        )
    }

    @Test("A refresh that fails keeps the options it was refreshing")
    func failedRefreshKeepsTheOptions() {
        let session = makeSession()
        session.beginTableOptionsLoad()
        #expect(session.tableOptions == .loading)

        session.settleTableOptions(.fetched(Self.latin))
        session.beginTableOptionsLoad()
        session.settleTableOptions(.failed("timed out"))

        #expect(session.loadedTableOptions == Self.latin)
        #expect(session.autoIncrementRead == .confirmed)
    }

    @Test("A first read that fails shows the failure and leaves nothing to stage against")
    func failedFirstReadHasNoBaseline() {
        let session = makeSession()
        session.beginTableOptionsLoad()
        session.settleTableOptions(.failed("Access denied"))

        session.adoptLoadedBaseline()

        #expect(session.tableOptions == .failed("Access denied"))
        #expect(session.changeManager.tableOptions.original == nil)
    }

    @Test("The loaded options are the change manager's baseline")
    func loadedOptionsBecomeTheBaseline() {
        let session = makeSession()
        session.settleTableOptions(.fetched(Self.latin))

        session.adoptLoadedBaseline()

        #expect(session.changeManager.tableOptions.original == Self.latin)
    }

    @Test("A written character set is adopted, and a written counter waits for the re-read")
    func writtenOptionsAdoptCharacterSetOnly() {
        let session = makeSession()
        session.settleTableOptions(.fetched(Self.latin))

        session.adoptWrittenTableOptions(from: [
            .modifyTableCharacterSet(
                old: TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci"),
                new: TableOptions(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", convertsColumns: true)
            ),
            .modifyAutoIncrement(old: 4, new: 2)
        ])

        #expect(session.loadedTableOptions == TableOptions(
            characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", autoIncrement: 4
        ))
        #expect(session.autoIncrementRead == .rereading)

        session.beginTableOptionsLoad()
        session.settleTableOptions(.fetched(TableOptions(
            characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", autoIncrement: 9
        )))

        #expect(session.autoIncrementRead == .confirmed)
        #expect(session.loadedTableOptions?.autoIncrement == 9)
    }

    @Test("A re-read that fails leaves the counter unconfirmed, and nothing stages against the old value")
    func failedRereadLeavesTheCounterUnconfirmed() {
        let session = makeSession()
        session.settleTableOptions(.fetched(Self.latin))
        session.adoptLoadedBaseline()
        session.adoptWrittenTableOptions(from: [.modifyAutoIncrement(old: 4, new: 500)])

        session.beginTableOptionsLoad()
        session.settleTableOptions(.failed("timed out"))
        session.adoptLoadedBaseline()

        #expect(session.autoIncrementRead == .unconfirmed)
        #expect(session.loadedTableOptions == Self.latin)
        let manager = session.changeManager
        #expect(!manager.tableOptions.isAutoIncrementConfirmed)

        var typed = Self.latin
        typed.autoIncrement = 6
        manager.stageTableOptions(typed)
        #expect(!manager.hasChanges)

        var utf8 = Self.latin
        utf8.characterSet = "utf8mb4"
        utf8.collation = "utf8mb4_0900_ai_ci"
        manager.stageTableOptions(utf8)
        #expect(manager.pendingChanges[.tableCharacterSet] != nil)
        #expect(manager.pendingChanges[.autoIncrement] == nil)
    }

    @Test("A cancelled re-read leaves the counter unconfirmed until a retry lands")
    func cancelledRereadWaitsForARetry() {
        let session = makeSession()
        session.settleTableOptions(.fetched(Self.latin))
        session.adoptWrittenTableOptions(from: [.modifyAutoIncrement(old: 4, new: 500)])

        session.settleTableOptions(.cancelled)
        #expect(session.autoIncrementRead == .unconfirmed)

        session.beginTableOptionsLoad()
        #expect(session.autoIncrementRead == .rereading)
        #expect(session.loadedTableOptions == Self.latin)

        var saved = Self.latin
        saved.autoIncrement = 500
        session.settleTableOptions(.fetched(saved))
        session.adoptLoadedBaseline()

        #expect(session.autoIncrementRead == .confirmed)
        let manager = session.changeManager
        #expect(manager.tableOptions.isAutoIncrementConfirmed)
        #expect(manager.tableOptions.original?.autoIncrement == 500)

        saved.autoIncrement = 600
        manager.stageTableOptions(saved)
        #expect(manager.pendingChanges[.autoIncrement] == .modifyAutoIncrement(old: 500, new: 600))
    }

    @Test("A catalog read that is cancelled caches nothing, and a failed refresh keeps the catalog")
    func catalogLoadStates() {
        let session = makeSession()
        session.beginTableOptionsCatalogLoad()
        session.settleTableOptionsCatalog(.cancelled)
        #expect(session.tableOptionsCatalog == .idle)

        session.beginTableOptionsCatalogLoad()
        session.settleTableOptionsCatalog(.fetched(Self.catalog))
        session.beginTableOptionsCatalogLoad()
        session.settleTableOptionsCatalog(.failed("timed out"))

        #expect(session.tableOptionsCatalog == .loaded(Self.catalog))
    }

    @Test("The Options sub-tab shows no grid")
    func optionsTabHasNoGrid() {
        let session = makeSession()
        session.selectedTab = .options

        #expect(session.activeGridModel == nil)
    }
}
