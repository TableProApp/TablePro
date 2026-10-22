//
//  DatabaseObjectRefIdentityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct DatabaseObjectRefIdentityTests {
    private func typeRef(
        _ name: String = "mood",
        identity: String? = "42",
        comment: String? = nil
    ) -> DatabaseObjectRef {
        let attributes = comment.map { [ObjectAttribute(label: "Comment", value: $0)] } ?? []
        return DatabaseObjectRef(
            userType: UserDefinedTypeInfo(name: name, kind: .enumeration, schema: "app", identity: identity, attributes: attributes),
            database: "shop"
        )
    }

    /// Saving a comment changes what the sidebar lists, and opening the type again used to open a
    /// second tab beside the one holding its queue.
    @Test("A type opened again after its comment changed returns to its tab")
    func commentChangeKeepsOneTab() {
        let manager = QueryTabManager()
        manager.addObjectSourceTab(objectRef: typeRef(comment: "old"))
        manager.addObjectSourceTab(objectRef: typeRef(comment: "new"))

        #expect(manager.tabs.count == 1)
    }

    /// Oracle and Dameng fill a routine's identity with its kind, so every procedure shares one.
    @Test("A shared identity never makes two names one object, and a different one tells a recreated type apart")
    func identityIsOnlyCompared() {
        let first = DatabaseObjectRef(kind: .procedure, name: "A", database: "db", schema: "S", identity: "PROCEDURE")
        let second = DatabaseObjectRef(kind: .procedure, name: "B", database: "db", schema: "S", identity: "PROCEDURE")
        #expect(!first.namesSameObject(as: second))
        #expect(!typeRef("mood", identity: "42").namesSameObject(as: typeRef("mood", identity: "43")))
        #expect(typeRef("mood", identity: nil).namesSameObject(as: typeRef("mood", identity: "42")))
    }

    @Test("Without an identity the name, schema and signature decide")
    func nameDecidesWithoutIdentity() {
        let view = DatabaseObjectRef(kind: .view, name: "v", database: "shop", schema: "app")
        let other = DatabaseObjectRef(kind: .view, name: "v", database: "shop", schema: "audit")
        #expect(view.namesSameObject(as: view))
        #expect(!view.namesSameObject(as: other))
    }
}
