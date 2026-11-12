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

    private var eventKind: SidebarServerObjectKind {
        SidebarServerObjectKind(
            id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar.badge.clock", scope: .container
        )
    }

    @Test("A ref written before server objects decodes with no server kind")
    func legacyRefHasNoServerKind() throws {
        let json = """
            {"kind":"trigger","name":"audit","database":"shop","schema":"public","table":"orders","attributes":[]}
            """
        let decoded = try JSONDecoder().decode(DatabaseObjectRef.self, from: Data(json.utf8))
        #expect(decoded.serverKind == nil)
        #expect(decoded.serverObject == nil)
    }

    @Test("A server object ref round-trips its kind and reads back as the object")
    func serverObjectRefRoundTrips() throws {
        let object = ServerObjectInfo(
            kindId: "event", name: "nightly", schema: "shop", detail: "Recurring",
            attributes: [ObjectAttribute(label: "Schedule", value: "EVERY 1 DAY")]
        )
        let ref = DatabaseObjectRef(serverObject: object, kind: eventKind, database: "shop")
        let decoded = try JSONDecoder().decode(DatabaseObjectRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded == ref)
        #expect(decoded.kind == .serverObject)
        #expect(decoded.serverKind?.id == "event")
        #expect(decoded.kindDisplayName == "Event")
        #expect(decoded.kindIconName == "calendar.badge.clock")
        #expect(decoded.serverObject?.kindId == "event")
        #expect(decoded.serverObject?.name == "nightly")
        #expect(decoded.displayIdentity == "shop.nightly")
    }

    @Test("Resolving the database keeps the server kind, and the tab is titled with the kind")
    @MainActor
    func serverObjectRefKeepsKind() {
        let ref = DatabaseObjectRef(serverObject: ServerObjectInfo(kindId: "event", name: "nightly"), kind: eventKind, database: "")
        #expect(ref.resolvingDatabase("shop").serverKind?.id == "event")
        #expect(QueryTabManager.objectSourceTitle(for: ref) == String(format: String(localized: "%1$@: %2$@"), "Event", "nightly"))
    }

    private var extensionKind: SidebarServerObjectKind {
        SidebarServerObjectKind(
            id: "extension", displayName: "Extension", pluralDisplayName: "Extensions", iconName: "puzzlepiece.extension",
            scope: .database
        )
    }

    @Test("A database-wide object is titled by its bare name, its schema left to the attributes")
    @MainActor
    func databaseScopedObjectHasABareName() throws {
        let object = ServerObjectInfo(kindId: "extension", name: "pgcrypto", schema: "public", identity: "16384")
        let ref = DatabaseObjectRef(serverObject: object, kind: extensionKind, database: "app")

        #expect(ref.isDatabaseScoped)
        #expect(ref.displayIdentity == "pgcrypto")
        #expect(QueryTabManager.objectSourceTitle(for: ref) == String(format: String(localized: "%1$@: %2$@"), "Extension", "pgcrypto"))
        #expect(ref.schema == "public")

        let decoded = try JSONDecoder().decode(DatabaseObjectRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded.serverKind?.scope == .database)
        #expect(decoded.displayIdentity == "pgcrypto")
    }

    @Test("A container object keeps its schema in its name")
    func containerObjectIsQualified() {
        let ref = DatabaseObjectRef(serverObject: ServerObjectInfo(kindId: "event", name: "nightly", schema: "shop"), kind: eventKind, database: "shop")

        #expect(!ref.isDatabaseScoped)
        #expect(ref.displayIdentity == "shop.nightly")
    }

    @Test("A server kind written without its scope decodes, and reads as a container kind")
    func serverKindWithoutScopeDecodes() throws {
        let json = """
            {"kind":"serverObject","name":"nightly","database":"shop","schema":"shop","attributes":[],\
            "serverKind":{"id":"event","displayName":"Event","iconName":"calendar.badge.clock"}}
            """
        let decoded = try JSONDecoder().decode(DatabaseObjectRef.self, from: Data(json.utf8))

        #expect(decoded.serverKind?.scope == nil)
        #expect(!decoded.isDatabaseScoped)
        #expect(decoded.displayIdentity == "shop.nightly")
    }

    @Test("Two server objects of different kinds are different objects")
    func serverKindSeparatesObjects() {
        let extensionKind = SidebarServerObjectKind(
            id: "extension", displayName: "Extension", pluralDisplayName: "Extensions", iconName: "puzzlepiece.extension",
            scope: .database
        )
        let event = DatabaseObjectRef(serverObject: ServerObjectInfo(kindId: "event", name: "x"), kind: eventKind, database: "shop")
        let ext = DatabaseObjectRef(serverObject: ServerObjectInfo(kindId: "extension", name: "x"), kind: extensionKind, database: "shop")
        #expect(!event.namesSameObject(as: ext))
        #expect(event.namesSameObject(as: event))
    }
}
