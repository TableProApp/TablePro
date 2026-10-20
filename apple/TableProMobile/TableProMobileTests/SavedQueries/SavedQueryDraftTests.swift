import Foundation
import TableProImport
@testable import TableProMobile
import TableProModels
import Testing

struct SavedQueryDraftTests {
    private let connectionId = UUID()

    @Test("Saving the editor's text trims it, and whitespace alone saves nothing")
    func savableSQLTrims() {
        #expect(SavedQueryDraft.savableSQL(from: "\n  SELECT 1;  \n") == "SELECT 1;")
        #expect(SavedQueryDraft.savableSQL(from: " \n\t ") == nil)
    }

    @Test("A new draft takes its name from the first line, unfiled, not global, with no keyword")
    func newDraftDefaults() {
        #expect(SavedQueryDraft(saving: "-- Monthly totals\nSELECT 1") == SavedQueryDraft(name: "Monthly totals"))
    }

    @Test("The keyword check runs in the Mac's order: spaces, then in use, then a shadowed SQL keyword")
    func keywordCheckOrder() {
        #expect(SavedQueryDraft(name: "q", keyword: "  ").keywordCheck(isAvailable: false) == .valid)
        #expect(SavedQueryDraft(name: "q", keyword: "two words").keywordCheck(isAvailable: false) == .containsSpaces)
        #expect(SavedQueryDraft(name: "q", keyword: "sel").keywordCheck(isAvailable: false) == .inUse)
        #expect(SavedQueryDraft(name: "q", keyword: " Select ").keywordCheck(isAvailable: true) == .shadowsSQLKeyword("Select"))
        #expect(SavedQueryDraft(name: "q", keyword: "sel").keywordCheck(isAvailable: true) == .valid)
    }

    @Test("A keyword warning still saves; a keyword error, a size over the limit, a blank name or blank SQL does not")
    func canSaveRules() {
        let draft = SavedQueryDraft(name: "Totals")
        let fits = { (check: SavedQueryKeywordCheck) in SavedQueryValidation(keywordCheck: check, exceedsSizeLimit: false) }
        #expect(draft.canSave(sql: "SELECT 1", validation: fits(.shadowsSQLKeyword("select"))))
        #expect(!draft.canSave(sql: "SELECT 1", validation: fits(.inUse)))
        #expect(!draft.canSave(sql: "SELECT 1", validation: fits(.containsSpaces)))
        #expect(!draft.canSave(sql: "SELECT 1", validation: SavedQueryValidation(keywordCheck: .valid, exceedsSizeLimit: true)))
        #expect(!SavedQueryDraft(name: "  ").canSave(sql: "SELECT 1", validation: fits(.valid)))
        #expect(!draft.canSave(sql: " \n", validation: fits(.valid)))
    }

    @Test("Name, SQL and keyword over 900 KB together do not save")
    func sizeLimit() {
        let limit = SavedQuerySize.maximumSyncableByteCount
        let draft = SavedQueryDraft(name: "ab", keyword: "k")
        let exceeds = { (length: Int) in
            draft.validation(
                sql: String(repeating: "x", count: length),
                savingOver: nil,
                changedSince: draft,
                connectionId: connectionId,
                folders: []
            ) { _, _ in true }.exceedsSizeLimit
        }
        #expect(!exceeds(limit - 3))
        #expect(exceeds(limit - 2))
    }

    @Test("A new query belongs to the open connection unless Global, with a trimmed name and keyword")
    func newQueryScope() {
        let now = Date(timeIntervalSince1970: 1_000)
        let folderId = UUID()
        let scoped = SavedQueryDraft(name: " Totals ", keyword: " tot ", folderId: folderId)
            .newQuery(sql: "SELECT 1", connectionId: connectionId, now: now)
        #expect(scoped.name == "Totals")
        #expect(scoped.query == "SELECT 1")
        #expect(scoped.keyword == "tot")
        #expect(scoped.folderId == folderId)
        #expect(scoped.connectionId == connectionId)
        #expect(scoped.sortOrder == 0)
        #expect(scoped.createdAt == now)
        #expect(scoped.updatedAt == now)

        let global = SavedQueryDraft(name: "Totals", isGlobal: true)
            .newQuery(sql: "SELECT 1", connectionId: connectionId, now: now)
        #expect(global.connectionId == nil)
        #expect(global.keyword == nil)
    }

    @Test("A rename writes only the name, keeping a folder and keyword a pull set after the form opened")
    func renameKeepsPulledChanges() {
        let opened = SavedQuery(name: "Totals", query: "SELECT 1", keyword: "tot", connectionId: connectionId)
        let pulledFolder = UUID()
        var live = opened
        live.folderId = pulledFolder
        live.keyword = "sum"
        let opening = SavedQueryDraft(query: opened)
        var edited = opening
        edited.name = "Monthly totals "

        edited.apply(to: &live, changedSince: opening, connectionId: connectionId, folders: [])

        #expect(live.name == "Monthly totals")
        #expect(live.folderId == pulledFolder)
        #expect(live.keyword == "sum")
        #expect(live.connectionId == connectionId)
        #expect(live.createdAt == opened.createdAt)
    }

    @Test("An untouched form changes nothing, and clearing the keyword removes it")
    func keywordClearAndNoOp() {
        let opened = SavedQuery(name: "Totals", query: "SELECT 1", keyword: "tot", connectionId: connectionId)
        let opening = SavedQueryDraft(query: opened)

        var untouched = opened
        opening.apply(to: &untouched, changedSince: opening, connectionId: connectionId, folders: [])
        #expect(untouched == opened)

        var cleared = opened
        var edited = opening
        edited.keyword = "  "
        edited.apply(to: &cleared, changedSince: opening, connectionId: connectionId, folders: [])
        #expect(cleared.keyword == nil)
    }

    @Test("Turning Global on drops a folder that belongs to one connection and keeps a global one")
    func globalDropsScopedFolder() {
        let scopedFolder = SavedQueryFolder(name: "Mine", connectionId: connectionId)
        let globalFolder = SavedQueryFolder(name: "Shared")
        let folders = [scopedFolder, globalFolder]

        let inScoped = SavedQueryDraft(name: "Totals", folderId: scopedFolder.id, isGlobal: true)
        #expect(inScoped.resolvingFolder(among: folders, connectionId: connectionId).folderId == nil)

        let inShared = SavedQueryDraft(name: "Totals", folderId: globalFolder.id, isGlobal: true)
        #expect(inShared.resolvingFolder(among: folders, connectionId: connectionId).folderId == globalFolder.id)

        let scoped = SavedQueryDraft(name: "Totals", folderId: scopedFolder.id)
        #expect(scoped.resolvingFolder(among: folders, connectionId: connectionId).folderId == scopedFolder.id)
    }

    @Test("A keyword is checked in the scope the row is saved with, even one a pull gave it while the form was open")
    func validationUsesTheSavedScope() {
        let opened = SavedQuery(name: "Totals", query: "SELECT 1", connectionId: connectionId)
        var madeGlobal = opened
        madeGlobal.connectionId = nil
        let opening = SavedQueryDraft(query: opened)
        var edited = opening
        edited.keyword = "tot"
        var checkedScopes: [UUID?] = []
        let heldInAnotherConnection = { (_: String, scope: UUID?) -> Bool in
            checkedScopes.append(scope)
            return scope != nil
        }

        let pulled = edited.validation(
            sql: opened.query,
            savingOver: madeGlobal,
            changedSince: opening,
            connectionId: connectionId,
            folders: [],
            isAvailable: heldInAnotherConnection
        )
        let deleted = edited.validation(
            sql: opened.query,
            savingOver: nil,
            changedSince: opening,
            connectionId: connectionId,
            folders: [],
            isAvailable: heldInAnotherConnection
        )

        #expect(pulled.keywordCheck == .inUse)
        #expect(deleted.keywordCheck == .valid)
        #expect(checkedScopes == [nil, connectionId])
    }

    @Test("A keyword or SQL a pull gave the row while the form was open is checked with the form's edits")
    func validationUsesThePulledRow() {
        let limit = SavedQuerySize.maximumSyncableByteCount
        let opened = SavedQuery(name: "Totals", query: "SELECT 1", connectionId: connectionId)
        var pulled = opened
        pulled.keyword = "tot"
        pulled.query = String(repeating: "x", count: limit - 10)
        let opening = SavedQueryDraft(query: opened)
        var edited = opening
        edited.isGlobal = true
        edited.name = "A longer name than before"

        let validation = edited.validation(
            sql: opened.query,
            savingOver: pulled,
            changedSince: opening,
            connectionId: connectionId,
            folders: []
        ) { _, scope in scope != nil }

        #expect(validation.keywordCheck == .inUse)
        #expect(validation.exceedsSizeLimit)
        #expect(!edited.canSave(sql: opened.query, validation: validation))
    }

    @Test("Saving a query as Global drops the stored row's scoped folder, even one a pull put it in")
    func applyGlobalChecksStoredFolder() {
        let scopedFolder = SavedQueryFolder(name: "Mine", connectionId: connectionId)
        let opened = SavedQuery(name: "Totals", query: "SELECT 1", connectionId: connectionId)
        var live = opened
        live.folderId = scopedFolder.id
        let opening = SavedQueryDraft(query: opened)
        var edited = opening
        edited.isGlobal = true

        edited.apply(to: &live, changedSince: opening, connectionId: connectionId, folders: [scopedFolder])

        #expect(live.connectionId == nil)
        #expect(live.folderId == nil)
    }

    @Test("A rename leaves a global query in a connection's folder where the Mac put it")
    func renameKeepsEarlierPlacement() {
        let scopedFolder = SavedQueryFolder(name: "Mine", connectionId: connectionId)
        let opened = SavedQuery(name: "Totals", query: "SELECT 1", folderId: scopedFolder.id)
        var live = opened
        let opening = SavedQueryDraft(query: opened)
        var edited = opening
        edited.name = "Monthly"

        edited.apply(to: &live, changedSince: opening, connectionId: connectionId, folders: [scopedFolder])

        #expect(live.name == "Monthly")
        #expect(live.folderId == scopedFolder.id)
    }

    @Test("A move refuses a folder narrower than the query, and None files it at the top level")
    func moveRules() {
        let scopedFolder = SavedQueryFolder(name: "Mine", connectionId: connectionId)
        let globalFolder = SavedQueryFolder(name: "Shared")
        var global = SavedQuery(name: "Totals", query: "SELECT 1")

        SavedQueryDraft.move(&global, to: scopedFolder)
        #expect(global.folderId == nil)

        SavedQueryDraft.move(&global, to: globalFolder)
        #expect(global.folderId == globalFolder.id)

        SavedQueryDraft.move(&global, to: nil)
        #expect(global.folderId == nil)

        var scoped = SavedQuery(name: "Totals", query: "SELECT 1", connectionId: connectionId)
        SavedQueryDraft.move(&scoped, to: scopedFolder)
        #expect(scoped.folderId == scopedFolder.id)
    }

    @Test("A rename takes the trimmed name; a blank, unchanged or oversized one does nothing")
    func renamedName() {
        let query = SavedQuery(name: "Totals", query: "SELECT 1")
        #expect(SavedQueryDraft.renamedName("  Monthly ", of: query) == "Monthly")
        #expect(SavedQueryDraft.renamedName("   ", of: query) == nil)
        #expect(SavedQueryDraft.renamedName("Totals ", of: query) == nil)
        let oversized = String(repeating: "n", count: SavedQuerySize.maximumSyncableByteCount)
        #expect(SavedQueryDraft.renamedName(oversized, of: query) == nil)
    }

    @Test("A folder name is trimmed, and must differ from the current one")
    func acceptedFolderName() {
        #expect(SavedQueryDraft.acceptedName(" Reports ", replacing: nil) == "Reports")
        #expect(SavedQueryDraft.acceptedName("  ", replacing: nil) == nil)
        #expect(SavedQueryDraft.acceptedName("Reports", replacing: "Reports") == nil)
    }

    @Test("A failed write says deleted when the record is gone, and not saved when it is still there")
    func writeFailureKind() {
        let query = SavedQuery(name: "Totals", query: "SELECT 1")
        #expect(SavedQueryWriteFailure.failedQueryWrite(query.id, in: []) == .queryDeleted)
        #expect(SavedQueryWriteFailure.failedQueryWrite(query.id, in: [query]) == .notSaved)

        let folder = SavedQueryFolder(name: "Shared")
        #expect(SavedQueryWriteFailure.failedFolderWrite(folder.id, in: []) == .folderDeleted)
        #expect(SavedQueryWriteFailure.failedFolderWrite(folder.id, in: [folder]) == .notSaved)
    }

    @Test("The row preview is the first line that is not blank or a comment, capped at 50 characters")
    func previewFirstLine() {
        #expect(SavedQueryPreview.firstLine(of: "\n  -- Totals\n\n   SELECT id FROM t  \nWHERE 1") == "SELECT id FROM t")
        #expect(SavedQueryPreview.firstLine(of: "-- only a comment\n  ") == nil)
        #expect(SavedQueryPreview.firstLine(of: "") == nil)
        #expect(SavedQueryPreview.firstLine(of: String(repeating: "x", count: 900_000)) == String(repeating: "x", count: 50))
    }

    @Test("The preview cap never splits a character")
    func previewKeepsCharactersWhole() {
        let preview = SavedQueryPreview.firstLine(of: String(repeating: "a", count: 49) + "\u{1F600} tail")
        #expect(preview == String(repeating: "a", count: 49))
    }
}
