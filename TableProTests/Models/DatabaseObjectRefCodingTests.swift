//
//  DatabaseObjectRefCodingTests.swift
//  TableProTests
//
//  A viewer tab persists its ref, so a ref written by one build has to decode on the next.
//

import Foundation
import Testing

@testable import TablePro

@Suite("DatabaseObjectRef coding")
struct DatabaseObjectRefCodingTests {
    @Test("A type ref round-trips with its kind")
    func userTypeRoundTrip() throws {
        let ref = DatabaseObjectRef(
            userType: UserDefinedTypeInfo(name: "mood", kind: .domain, schema: "app", identity: "16387"),
            database: "shop"
        )
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(DatabaseObjectRef.self, from: data)
        #expect(decoded == ref)
        #expect(decoded.typeKind == .domain)
    }

    /// A tab persisted before types existed carries no `typeKind` at all.
    @Test("A routine ref written without typeKind still decodes")
    func legacyRefDecodes() throws {
        let json = """
            {"kind":"function","name":"transform","database":"shop","schema":"public","attributes":[]}
            """
        let decoded = try JSONDecoder().decode(DatabaseObjectRef.self, from: Data(json.utf8))
        #expect(decoded.kind == .function)
        #expect(decoded.typeKind == nil)
        #expect(decoded.routine?.name == "transform")
    }

    @Test("Resolving the database keeps the type kind")
    func resolvingDatabaseKeepsTypeKind() {
        let ref = DatabaseObjectRef(
            userType: UserDefinedTypeInfo(name: "mood", kind: .range, schema: "app"),
            database: ""
        )
        #expect(ref.resolvingDatabase("shop").typeKind == .range)
        #expect(ref.resolvingDatabase("shop").database == "shop")
    }
}
