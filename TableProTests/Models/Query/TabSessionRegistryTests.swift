//
//  TabSessionRegistryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TabSessionRegistry")
@MainActor
struct TabSessionRegistryTests {
    @Test("session(for:) returns nil for an unregistered id")
    func sessionForUnregisteredIdIsNil() {
        let registry = TabSessionRegistry()
        #expect(registry.session(for: UUID()) == nil)
    }

    @Test("register stores the session by id")
    func registerStoresSession() {
        let registry = TabSessionRegistry()
        let session = TabSession()

        registry.register(session)

        #expect(registry.session(for: session.id) === session)
    }

    @Test("register replaces an existing session for the same id")
    func registerReplacesExisting() {
        let registry = TabSessionRegistry()
        let id = UUID()
        let first = TabSession(id: id)
        let second = TabSession(id: id)

        registry.register(first)
        registry.register(second)

        #expect(registry.session(for: id) === second)
    }

    @Test("unregister removes the entry")
    func unregisterRemovesEntry() {
        let registry = TabSessionRegistry()
        let session = TabSession()
        registry.register(session)

        registry.unregister(id: session.id)

        #expect(registry.session(for: session.id) == nil)
    }

    @Test("unregister of an unknown id is a no-op")
    func unregisterUnknownIdIsNoOp() {
        let registry = TabSessionRegistry()
        registry.unregister(id: UUID())
    }

    @Test("removeAll clears every registered session")
    func removeAllClearsAll() {
        let registry = TabSessionRegistry()
        let first = TabSession()
        let second = TabSession()
        registry.register(first)
        registry.register(second)

        registry.removeAll()

        #expect(registry.session(for: first.id) == nil)
        #expect(registry.session(for: second.id) == nil)
    }

    @Test("Multiple sessions coexist under distinct ids")
    func multipleSessionsCoexist() {
        let registry = TabSessionRegistry()
        let first = TabSession()
        let second = TabSession()

        registry.register(first)
        registry.register(second)

        #expect(registry.session(for: first.id) === first)
        #expect(registry.session(for: second.id) === second)
    }

    // MARK: - dataRevision

    private func makeRows(_ names: [String]) -> TableRows {
        let rows = ContiguousArray(
            names.enumerated().map { index, name in
                Row(id: .existing(index), values: [.text(name)])
            }
        )
        return TableRows(rows: rows, columns: ["name"], columnTypes: [.text(rawType: nil)])
    }

    @Test("setTableRows bumps dataRevision so a same-size result still counts as a change")
    func setTableRowsBumpsDataRevision() {
        let registry = TabSessionRegistry()
        let session = TabSession()
        registry.register(session)

        registry.setTableRows(makeRows(["a", "b"]), for: session.id)
        let afterFirst = session.dataRevision
        registry.setTableRows(makeRows(["c", "d"]), for: session.id)

        #expect(afterFirst > 0)
        #expect(session.dataRevision > afterFirst)
    }

    @Test("updateTableRows bumps dataRevision")
    func updateTableRowsBumpsDataRevision() {
        let registry = TabSessionRegistry()
        let session = TabSession()
        registry.register(session)
        registry.setTableRows(makeRows(["a"]), for: session.id)
        let before = session.dataRevision

        registry.updateTableRows(for: session.id) { rows in
            rows.rows.append(Row(id: .existing(1), values: [.text("b")]))
        }

        #expect(session.dataRevision > before)
    }

    @Test("removeTableRows bumps dataRevision")
    func removeTableRowsBumpsDataRevision() {
        let registry = TabSessionRegistry()
        let session = TabSession()
        registry.register(session)
        registry.setTableRows(makeRows(["a"]), for: session.id)
        let before = session.dataRevision

        registry.removeTableRows(for: session.id)

        #expect(session.dataRevision > before)
    }

    @Test("evict bumps dataRevision, and leaves it alone when there is nothing to evict")
    func evictBumpsDataRevision() {
        let registry = TabSessionRegistry()
        let session = TabSession()
        registry.register(session)
        registry.setTableRows(makeRows(["a"]), for: session.id)
        let before = session.dataRevision

        registry.evict(for: session.id)
        let afterEvict = session.dataRevision
        registry.evict(for: session.id)

        #expect(afterEvict > before)
        #expect(session.dataRevision == afterEvict)
        #expect(session.tableRows.index(of: .existing(0)) == nil)
    }
}
