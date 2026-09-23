//
//  SQLFavoriteEditDraftTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SQLFavoriteEditDraft")
struct SQLFavoriteEditDraftTests {
    private static let seedScript = (1...10_000)
        .map { "INSERT INTO users (id, email) VALUES (\($0), 'user\($0)@example.com');" }
        .joined(separator: "\n")

    private static let lastSeedStatement = "INSERT INTO users (id, email) VALUES (10000, 'user10000@example.com');"

    private func makeDraft(
        name: String = "Seed users",
        query: String = SQLFavoriteEditDraftTests.seedScript,
        keyword: String = "",
        folderId: UUID? = nil,
        connectionId: UUID? = nil
    ) -> SQLFavoriteEditDraft {
        SQLFavoriteEditDraft(
            name: name,
            query: query,
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId
        )
    }

    @Test("A new favorite keeps a query past 500,000 characters whole")
    func newFavoriteKeepsWholeQuery() {
        #expect((Self.seedScript as NSString).length > 500_000)

        let favorite = makeDraft().newFavorite()

        #expect(favorite.query == Self.seedScript)
        #expect(favorite.query.hasSuffix(Self.lastSeedStatement))
    }

    @Test("Editing a favorite keeps a query past 500,000 characters whole")
    func editedFavoriteKeepsWholeQuery() {
        let existing = SQLFavorite(name: "Old", query: "SELECT 1", sortOrder: 7)
        let editedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let updated = makeDraft().applied(to: existing, at: editedAt)

        #expect(updated.query == Self.seedScript)
        #expect(updated.name == "Seed users")
        #expect(updated.updatedAt == editedAt)
    }

    @Test("Editing keeps the favorite's identity, order and creation date")
    func editKeepsIdentity() {
        let existing = SQLFavorite(name: "Old", query: "SELECT 1", sortOrder: 7)

        let updated = makeDraft(query: "SELECT 2").applied(to: existing, at: Date())

        #expect(updated.id == existing.id)
        #expect(updated.sortOrder == 7)
        #expect(updated.createdAt == existing.createdAt)
    }

    @Test("Name and keyword are trimmed and a blank keyword is dropped")
    func trimsNameAndKeyword() {
        #expect(makeDraft(name: "  Seed  ").name == "Seed")
        #expect(makeDraft(keyword: "  seed  ").keyword == "seed")
        #expect(makeDraft(keyword: "   ").keyword == nil)
    }

    @Test("Folder and scope carry through to the saved favorite")
    func carriesFolderAndScope() {
        let folderId = UUID()
        let connectionId = UUID()

        let scoped = makeDraft(folderId: folderId, connectionId: connectionId).newFavorite()
        #expect(scoped.folderId == folderId)
        #expect(scoped.connectionId == connectionId)

        let global = makeDraft(connectionId: nil).applied(
            to: SQLFavorite(name: "Old", query: "SELECT 1", connectionId: connectionId),
            at: Date()
        )
        #expect(global.connectionId == nil)
    }

    @Test("Size validation reads the values that are saved")
    func sizeValidationReadsSavedValues() {
        let limit = SQLFavoriteSizeValidation.maximumSyncableByteCount
        let query = String(repeating: "a", count: limit - 4)

        #expect(makeDraft(name: "  ab  ", query: query, keyword: "  cd  ").sizeValidation == .valid)
        #expect(makeDraft(name: "abc", query: query, keyword: "cd").sizeValidation == .tooLarge)
        #expect(makeDraft().sizeValidation == .valid)
    }
}
