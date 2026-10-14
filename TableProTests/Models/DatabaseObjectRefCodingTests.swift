//
//  DatabaseObjectRefCodingTests.swift
//  TableProTests
//
//  A viewer tab persists its ref, so a ref written by one build has to decode on the next.
//

import Foundation
import Testing

@testable import TablePro

struct DatabaseObjectRefCodingTests {
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
