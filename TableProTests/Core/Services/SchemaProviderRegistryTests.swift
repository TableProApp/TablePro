//
//  SchemaProviderRegistryTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("SchemaProviderRegistry")
@MainActor
struct SchemaProviderRegistryTests {
    @Test("getOrCreate returns new provider for unknown connectionId")
    func getOrCreateNewProvider() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        let provider = registry.getOrCreate(for: id)
        #expect(registry.provider(for: id) === provider)
    }

    @Test("getOrCreate returns same provider for same connectionId")
    func getOrCreateReturnsSameProvider() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        let p1 = registry.getOrCreate(for: id)
        let p2 = registry.getOrCreate(for: id)
        #expect(p1 === p2)
    }

    @Test("provider(for:) returns nil for unknown connectionId")
    func providerForUnknownReturnsNil() {
        let registry = SchemaProviderRegistry()
        #expect(registry.provider(for: UUID()) == nil)
    }

    @Test("provider(for:) returns provider after getOrCreate")
    func providerForKnownReturnsProvider() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        let created = registry.getOrCreate(for: id)
        #expect(registry.provider(for: id) === created)
    }

    @Test("retain increments refcount, prevents purge")
    func retainPreventsRemoval() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        _ = registry.getOrCreate(for: id)
        registry.retain(for: id)
        registry.purgeUnused()
        #expect(registry.provider(for: id) != nil)
    }

    @Test("release decrements refcount to zero, schedules deferred removal")
    func releaseSchedulesDeferredRemoval() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        _ = registry.getOrCreate(for: id)
        registry.retain(for: id)
        registry.release(for: id)
        #expect(registry.provider(for: id) != nil)
    }

    @Test("clear removes provider, refcount, and pending removal")
    func clearRemovesEverything() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        _ = registry.getOrCreate(for: id)
        registry.retain(for: id)
        registry.clear(for: id)
        #expect(registry.provider(for: id) == nil)
    }

    @Test("purgeUnused removes orphaned providers with zero refcount and no pending task")
    func purgeRemovesOrphans() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        _ = registry.getOrCreate(for: id)
        registry.purgeUnused()
        #expect(registry.provider(for: id) == nil)
    }

    @Test("purgeUnused does not remove providers with pending removal task")
    func purgeKeepsProvidersWithPendingTask() {
        let registry = SchemaProviderRegistry()
        let id = UUID()
        _ = registry.getOrCreate(for: id)
        registry.retain(for: id)
        registry.release(for: id)
        registry.purgeUnused()
        #expect(registry.provider(for: id) != nil)
    }

    @Test("multiple connections are independent")
    func multipleConnectionsIndependent() {
        let registry = SchemaProviderRegistry()
        let id1 = UUID(), id2 = UUID()
        let p1 = registry.getOrCreate(for: id1)
        let p2 = registry.getOrCreate(for: id2)
        #expect(p1 !== p2)
        registry.clear(for: id1)
        #expect(registry.provider(for: id1) == nil)
        #expect(registry.provider(for: id2) != nil)
    }
}
