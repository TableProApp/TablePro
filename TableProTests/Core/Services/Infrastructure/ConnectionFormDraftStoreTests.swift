//
//  ConnectionFormDraftStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionFormDraftStore", .serialized)
@MainActor
struct ConnectionFormDraftStoreTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    @Test("A staged draft is returned once and then cleared")
    func aStagedDraftIsReturnedOnceThenCleared() {
        let store = ConnectionFormDraftStore.shared
        let draftId = store.stage(ConnectionFormDraft(type: .mysql))

        #expect(store.consume(draftId)?.type == .mysql)
        #expect(store.consume(draftId) == nil)
    }

    @Test("Consuming an unknown draft id returns nil")
    func consumingAnUnknownDraftIdReturnsNil() {
        #expect(ConnectionFormDraftStore.shared.consume(UUID()) == nil)
    }

    @Test("Two staged drafts do not contaminate each other")
    func twoStagedDraftsDoNotContaminateEachOther() throws {
        let store = ConnectionFormDraftStore.shared
        let shop = try parse("mysql://sam:secret@shop.example.com:3306/shop")
        let books = try parse("postgres://ana:hunter2@books.example.com:5432/books")

        let shopId = store.stage(ConnectionFormDraft(parsedURL: shop))
        let booksId = store.stage(ConnectionFormDraft(parsedURL: books))

        #expect(store.consume(booksId)?.parsedURL?.database == "books")
        #expect(store.consume(shopId)?.parsedURL?.database == "shop")
    }

    @Test("A staged URL keeps the credentials it was parsed with")
    func aStagedURLKeepsItsCredentials() throws {
        let store = ConnectionFormDraftStore.shared
        let parsed = try parse("mysql://sam:secret@shop.example.com:3306/shop")
        let draftId = store.stage(ConnectionFormDraft(parsedURL: parsed))

        let draft = store.consume(draftId)
        #expect(draft?.parsedURL?.username == "sam")
        #expect(draft?.parsedURL?.password == "secret")
        #expect(draft?.parsedURL?.host == "shop.example.com")
    }

    @Test("A draft with no type and no URL stages an empty form")
    func anEmptyDraftStagesAnEmptyForm() {
        let store = ConnectionFormDraftStore.shared
        let draftId = store.stage(ConnectionFormDraft())

        let draft = store.consume(draftId)
        #expect(draft != nil)
        #expect(draft?.type == nil)
        #expect(draft?.parsedURL == nil)
    }
}
