//
//  SchemaProviderRegistryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SchemaProviderRegistry")
@MainActor
struct SchemaProviderRegistryTests {
    private func makeScope(
        _ connectionId: UUID = UUID(),
        database: String = "app",
        schema: String? = nil
    ) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    @Test("getOrCreate returns new provider for unknown scope")
    func getOrCreateNewProvider() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        let provider = registry.getOrCreate(for: scope)
        #expect(registry.provider(for: scope) === provider)
    }

    @Test("getOrCreate returns same provider for same scope")
    func getOrCreateReturnsSameProvider() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        let p1 = registry.getOrCreate(for: scope)
        let p2 = registry.getOrCreate(for: scope)
        #expect(p1 === p2)
    }

    @Test("provider(for:) returns nil for unknown scope")
    func providerForUnknownReturnsNil() {
        let registry = SchemaProviderRegistry()
        #expect(registry.provider(for: makeScope()) == nil)
    }

    @Test("provider(for:) returns provider after getOrCreate")
    func providerForKnownReturnsProvider() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        let created = registry.getOrCreate(for: scope)
        #expect(registry.provider(for: scope) === created)
    }

    @Test("retain increments refcount, prevents purge")
    func retainPreventsRemoval() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        _ = registry.getOrCreate(for: scope)
        registry.retain(for: scope)
        registry.purgeUnused()
        #expect(registry.provider(for: scope) != nil)
    }

    @Test("release decrements refcount to zero, schedules deferred removal")
    func releaseSchedulesDeferredRemoval() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        _ = registry.getOrCreate(for: scope)
        registry.retain(for: scope)
        registry.release(for: scope)
        #expect(registry.provider(for: scope) != nil)
    }

    @Test("clear removes provider, refcount, and pending removal")
    func clearRemovesEverything() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        _ = registry.getOrCreate(for: scope)
        registry.retain(for: scope)
        registry.clear(for: scope)
        #expect(registry.provider(for: scope) == nil)
    }

    @Test("purgeUnused removes orphaned providers with zero refcount and no pending task")
    func purgeRemovesOrphans() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        _ = registry.getOrCreate(for: scope)
        registry.purgeUnused()
        #expect(registry.provider(for: scope) == nil)
    }

    @Test("purgeUnused does not remove providers with pending removal task")
    func purgeKeepsProvidersWithPendingTask() {
        let registry = SchemaProviderRegistry()
        let scope = makeScope()
        _ = registry.getOrCreate(for: scope)
        registry.retain(for: scope)
        registry.release(for: scope)
        registry.purgeUnused()
        #expect(registry.provider(for: scope) != nil)
    }

    @Test("multiple connections are independent")
    func multipleConnectionsIndependent() {
        let registry = SchemaProviderRegistry()
        let first = makeScope(), second = makeScope()
        let p1 = registry.getOrCreate(for: first)
        let p2 = registry.getOrCreate(for: second)
        #expect(p1 !== p2)
        registry.clear(for: first)
        #expect(registry.provider(for: first) == nil)
        #expect(registry.provider(for: second) != nil)
    }

    @Test("two databases of one connection get their own provider")
    func scopesOfOneConnectionGetTheirOwnProvider() {
        let registry = SchemaProviderRegistry()
        let connectionId = UUID()
        let shop = makeScope(connectionId, database: "shop")
        let inventory = makeScope(connectionId, database: "inventory")

        #expect(registry.getOrCreate(for: shop) !== registry.getOrCreate(for: inventory))
    }

    @Test("clearing a connection drops every scope's provider, other connections survive")
    func clearConnectionDropsEveryScope() {
        let registry = SchemaProviderRegistry()
        let connectionId = UUID()
        let shop = makeScope(connectionId, database: "shop")
        let inventory = makeScope(connectionId, database: "inventory")
        let other = makeScope(database: "shop")
        _ = registry.getOrCreate(for: shop)
        _ = registry.getOrCreate(for: inventory)
        _ = registry.getOrCreate(for: other)
        registry.retain(for: shop)
        registry.retain(for: inventory)

        registry.clear(connectionId: connectionId)

        #expect(registry.provider(for: shop) == nil)
        #expect(registry.provider(for: inventory) == nil)
        #expect(registry.provider(for: other) != nil)
    }
}
