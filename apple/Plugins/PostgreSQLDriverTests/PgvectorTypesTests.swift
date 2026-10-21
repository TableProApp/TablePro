//
//  PgvectorTypesTests.swift
//  TableProTests
//

import Foundation
import Testing

struct PgvectorTypesTests {
    @Test("The probe names each pgvector type and its array, and ignores any other row")
    func probeRowsNameTypesAndArrays() {
        let rows: [[String?]] = [
            ["16385", "16391", "vector"],
            ["16498", "16504", "halfvec"],
            ["16633", "0", "sparsevec"],
            ["17000", "17001", "geometry"],
            ["oops", "1", "vector"],
            ["18000", nil]
        ]

        #expect(PgvectorTypes.names(fromProbeRows: rows) == [
            16_385: "vector",
            16_391: "vector[]",
            16_498: "halfvec",
            16_504: "halfvec[]",
            16_633: "sparsevec"
        ])
    }

    @Test("The probe asks for base types only, so a composite named vector is not one")
    func probeQueryAsksForBaseTypes() {
        #expect(PgvectorTypes.probeQuery.contains("t.typtype = 'b'"))
        #expect(PgvectorTypes.probeQuery.contains("'vector', 'halfvec', 'sparsevec'"))
    }

    @Test("A positive modifier is the dimension count, an array keeps its brackets after it")
    func modifierSpellsDimensions() {
        #expect(PgvectorTypes.spelling(of: "vector", modifier: 1_536) == "vector(1536)")
        #expect(PgvectorTypes.spelling(of: "halfvec", modifier: 3) == "halfvec(3)")
        #expect(PgvectorTypes.spelling(of: "sparsevec", modifier: 1_000) == "sparsevec(1000)")
        #expect(PgvectorTypes.spelling(of: "vector[]", modifier: 3) == "vector(3)[]")
    }

    @Test("An expression's -1 and any other type's modifier leave the name alone")
    func otherModifiersLeaveTheName() {
        #expect(PgvectorTypes.spelling(of: "vector", modifier: -1) == "vector")
        #expect(PgvectorTypes.spelling(of: "varchar", modifier: 54) == "varchar")
        #expect(PgvectorTypes.spelling(of: "numeric", modifier: 655_366) == "numeric")
        #expect(PgvectorTypes.spelling(of: "ENUM(vector)", modifier: 3) == "ENUM(vector)")
    }

    @Test("A result column reads the dimension count from the oid the probe registered")
    func registrySpellsAProbedOid() {
        let registry = LibPQTypeNameRegistry()
        registry.merge(PgvectorTypes.names(fromProbeRows: [["16385", "16391", "vector"]]))

        #expect(registry.name(for: 16_385, modifier: 1_536) == "vector(1536)")
        #expect(registry.name(for: 16_385, modifier: -1) == "vector")
        #expect(registry.name(for: 16_391, modifier: 3) == "vector(3)[]")
        #expect(registry.name(for: 1_043, modifier: 54) == "varchar")
        #expect(registry.unresolvedOids(in: [16_385, 16_391]).isEmpty)
    }
}
