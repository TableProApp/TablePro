//
//  TabSessionRegistryTests.swift
//  TableProTests
//

import Foundation
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
}
