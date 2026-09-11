//
//  AIChatStorageScopingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIChatStorage scoping", .serialized)
struct AIChatStorageScopingTests {
    private func makeStorage() -> (AIChatStorage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chat-scoping-\(UUID().uuidString)", isDirectory: true)
        return (AIChatStorage(directory: directory), directory)
    }

    private func conversation(
        connectionId: UUID?,
        title: String,
        updatedAt: Date = Date()
    ) -> AIConversation {
        AIConversation(
            title: title,
            messages: [],
            updatedAt: updatedAt,
            connectionId: connectionId,
            connectionName: "localhost"
        )
    }

    @Test("Listing by connection returns that connection's conversations and no other connection's")
    func listingIsScopedToTheConnection() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = UUID()
        let theirs = UUID()

        await storage.save(conversation(connectionId: mine, title: "mine"))
        await storage.save(conversation(connectionId: theirs, title: "theirs"))

        let listed = await storage.loadAll(connectionId: mine)

        #expect(listed.map(\.title) == ["mine"])
    }

    @Test("Two connections sharing a name stay distinct")
    func duplicateConnectionNamesStayDistinct() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID()
        let second = UUID()

        await storage.save(conversation(connectionId: first, title: "first localhost"))
        await storage.save(conversation(connectionId: second, title: "second localhost"))

        let firstListed = await storage.loadAll(connectionId: first)
        let secondListed = await storage.loadAll(connectionId: second)

        #expect(firstListed.map(\.title) == ["first localhost"])
        #expect(secondListed.map(\.title) == ["second localhost"])
    }

    @Test("Orphans stay listed for every connection so history is never hidden")
    func orphansAreListedEverywhere() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = UUID()
        let theirs = UUID()

        await storage.save(conversation(connectionId: nil, title: "orphan"))
        await storage.save(conversation(connectionId: mine, title: "mine"))

        let listedForMine = await storage.loadAll(connectionId: mine)
        let listedForTheirs = await storage.loadAll(connectionId: theirs)

        #expect(Set(listedForMine.map(\.title)) == ["orphan", "mine"])
        #expect(listedForTheirs.map(\.title) == ["orphan"])
    }

    @Test("A session with no connection lists only the orphans")
    func noConnectionListsOrphansOnly() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }

        await storage.save(conversation(connectionId: nil, title: "orphan"))
        await storage.save(conversation(connectionId: UUID(), title: "attached"))

        let listed = await storage.loadAll(connectionId: nil)

        #expect(listed.map(\.title) == ["orphan"])
    }

    @Test("Loading by id returns the one record and nil for an unknown id")
    func loadByIdReturnsOneRecord() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = conversation(connectionId: UUID(), title: "target")

        await storage.save(target)

        let loaded = await storage.load(id: target.id)
        #expect(loaded?.title == "target")
        #expect(await storage.load(id: UUID()) == nil)
    }

    @Test("Two sessions on two connections write two records; neither overwrites the other")
    func twoSessionsWriteTwoRecords() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = conversation(connectionId: UUID(), title: "first")
        let second = conversation(connectionId: UUID(), title: "second")

        await storage.save(first)
        await storage.save(second)

        let all = await storage.loadAll()
        #expect(all.count == 2)
        #expect(await storage.load(id: first.id)?.title == "first")
        #expect(await storage.load(id: second.id)?.title == "second")
    }

    @Test("Deleting one conversation leaves the other intact")
    func deletingOneLeavesTheOther() async throws {
        let (storage, directory) = makeStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = conversation(connectionId: UUID(), title: "kept")
        let removed = conversation(connectionId: UUID(), title: "removed")

        await storage.save(kept)
        await storage.save(removed)
        await storage.delete(removed.id)

        #expect(await storage.load(id: removed.id) == nil)
        #expect(await storage.load(id: kept.id)?.title == "kept")
    }
}
