//
//  CodableListPreferenceStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CodableListPreferenceStore")
struct CodableListPreferenceStoreTests {
    private struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        var label: String
    }

    private func makeStore() throws -> CodableListPreferenceStore<Item> {
        let defaults = try #require(UserDefaults(suiteName: "codablelist-\(UUID().uuidString)"))
        return CodableListPreferenceStore(key: DefaultsKey<[Item]>("com.TablePro.test.items"), store: defaults)
    }

    @Test("Loading an unset key returns an empty list")
    func loadReturnsEmptyWhenUnset() throws {
        let store = try makeStore()
        #expect(store.load().isEmpty)
    }

    @Test("Adding appends and persists")
    func addAppendsAndPersists() throws {
        let store = try makeStore()
        let item = Item(id: UUID(), label: "a")
        store.add(item)
        #expect(store.load() == [item])
    }

    @Test("Removing by id drops the matching element")
    func removeByIdDropsElement() throws {
        let store = try makeStore()
        let first = Item(id: UUID(), label: "a")
        let second = Item(id: UUID(), label: "b")
        store.save([first, second])
        store.remove(id: first.id)
        #expect(store.load() == [second])
    }

    @Test("Updating replaces the element with the same id")
    func updateReplacesMatchingElement() throws {
        let store = try makeStore()
        var item = Item(id: UUID(), label: "a")
        store.add(item)
        item.label = "a2"
        store.update(item)
        #expect(store.load() == [item])
    }
}
