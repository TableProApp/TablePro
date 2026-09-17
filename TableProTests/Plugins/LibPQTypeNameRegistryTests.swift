//
//  LibPQTypeNameRegistryTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("LibPQ type name registry")
struct LibPQTypeNameRegistryTests {
    @Test("A later merge overwrites an oid learned earlier and keeps the ones it does not name")
    func mergeOverwritesLearnedName() {
        let registry = LibPQTypeNameRegistry()
        registry.merge([16_385: "ENUM(mood)", 16_390: "ENUM(status)"])
        registry.merge([16_385: "ENUM(feeling)"])

        #expect(registry.name(for: 16_385) == "ENUM(feeling)")
        #expect(registry.name(for: 16_390) == "ENUM(status)")
    }

    @Test("A name resolves from what was learned, then the built-in table, then unresolved")
    func nameFallbackOrder() {
        let registry = LibPQTypeNameRegistry()
        registry.merge([23: "positive"])

        #expect(registry.name(for: 23) == "positive")
        #expect(registry.name(for: 1_043) == "varchar")
        #expect(registry.name(for: 16_385) == PostgreSQLCatalogTypeNames.unresolved)

        registry.merge([16_385: "ENUM(mood)"])
        #expect(registry.name(for: 16_385) == "ENUM(mood)")
    }

    @Test("Only oids neither learned nor built in are unresolved, in the order and multiplicity asked")
    func unresolvedOidsSkipLearnedAndBuiltIn() {
        let registry = LibPQTypeNameRegistry()
        registry.merge([16_390: "ENUM(status)"])

        #expect(registry.unresolvedOids(in: [16_386, 23, 16_385, 16_390, 16_386]) == [16_386, 16_385, 16_386])
        #expect(registry.unresolvedOids(in: []).isEmpty)
    }

    /// Otherwise a column whose type the catalog does not know would send a lookup with every
    /// result that carries it.
    @Test("An oid learned as unresolved is not unresolved again and keeps the unresolved spelling")
    func learnedUnresolvedOidIsNotAskedAgain() {
        let registry = LibPQTypeNameRegistry()
        registry.merge(PostgreSQLCatalogTypeNames.names(for: [99_999], rows: []))

        #expect(registry.unresolvedOids(in: [99_999]).isEmpty)
        #expect(registry.name(for: 99_999) == PostgreSQLCatalogTypeNames.unresolved)
    }

    @Test("Setting the PostGIS types replaces the previous map rather than merging into it")
    func postgisTypesAreReplaced() {
        let registry = LibPQTypeNameRegistry()
        let geometry = PostGISType(name: "geometry", schema: "public")
        let geography = PostGISType(name: "geography", schema: "gis")
        #expect(registry.postgisTypes.isEmpty)

        registry.setPostgisTypes([17_000: geometry])
        registry.setPostgisTypes([17_001: geography])

        #expect(registry.postgisTypes == [17_001: geography])
        #expect(registry.name(for: 17_001) == PostgreSQLCatalogTypeNames.unresolved)
    }

    @Test("Merges and reads from many threads at once all land")
    func concurrentMergesAllLand() {
        let registry = LibPQTypeNameRegistry()
        let count = 2_000

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let oid = UInt32(100_000 + index)
            registry.merge([oid: "type_\(index)"])
            _ = registry.unresolvedOids(in: [oid, oid + 1])
            _ = registry.name(for: oid)
        }

        let oids = (0..<count).map { UInt32(100_000 + $0) }
        #expect(registry.unresolvedOids(in: oids).isEmpty)
        #expect(registry.name(for: 100_000 + 1_234) == "type_1234")
    }
}
