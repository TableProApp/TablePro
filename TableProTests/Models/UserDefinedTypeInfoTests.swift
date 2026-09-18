//
//  UserDefinedTypeInfoTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("UserDefinedTypeInfo")
struct UserDefinedTypeInfoTests {
    @Test("Identity is the qualified name, so an edited enum is still the same row")
    func identityIgnoresLabelsAndDefinition() {
        let before = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "app", enumLabels: ["sad"])
        let after = UserDefinedTypeInfo(
            name: "mood", kind: .enumeration, schema: "app", enumLabels: ["sad", "ok"], definition: "CREATE TYPE …"
        )
        #expect(before == after)
        #expect(before.id == "type_app.mood")
        #expect(Set([before, after]).count == 1)
    }

    @Test("Two schemas may each hold a type of the same name")
    func schemaSeparatesSameName() {
        let one = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "app")
        let two = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "sales")
        #expect(one != two)
        #expect(one.qualifiedName == "app.mood")
    }

    @Test("A type with no schema is named bare")
    func bareName() {
        let type = UserDefinedTypeInfo(name: "mood", kind: .enumeration)
        #expect(type.qualifiedName == "mood")
        #expect(type.id == "type_mood")
    }

    @Test("The plugin transfer type round-trips, identity and labels included")
    func pluginRoundTrip() {
        let plugin = PluginUserDefinedTypeInfo(
            name: "point", kind: .composite, schema: "app", identity: "16395",
            fields: [PluginUserDefinedTypeField(name: "x", type: "text", collation: "pg_catalog.\"C\"")],
            columnTypeSpelling: "app.point",
            definition: "CREATE TYPE …",
            attributes: [PluginObjectAttribute(label: "Owner", value: "postgres")]
        )
        let app = UserDefinedTypeInfo(plugin)
        #expect(app.kind == .composite)
        #expect(app.identity == "16395")
        #expect(app.fields == [UserDefinedTypeInfo.Field(name: "x", type: "text", collation: "pg_catalog.\"C\"")])
        #expect(app.columnTypeSpelling == "app.point")
        #expect(app.attributes == [ObjectAttribute(label: "Owner", value: "postgres")])

        let back = app.pluginType
        #expect(back.kind == .composite)
        #expect(back.identity == "16395")
        #expect(back.fields == plugin.fields)
        #expect(back.columnTypeSpelling == "app.point")
        #expect(back.definition == "CREATE TYPE …")
    }

    @Test("Every named kind maps both ways")
    func kindMapping() {
        for kind in [PluginUserDefinedTypeKind.enumeration, .composite, .domain, .range] {
            #expect(UserDefinedTypeInfo.Kind(kind).pluginKind == kind)
        }
        #expect(UserDefinedTypeInfo.Kind.other.pluginKind == nil)
    }

    @Test("A type ref carries the kind so the viewer knows what it opened")
    func objectRef() {
        let type = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "app", identity: "16387")
        let ref = DatabaseObjectRef(userType: type, database: "shop")
        #expect(ref.kind == .userType)
        #expect(ref.typeKind == .enumeration)
        #expect(ref.identity == "16387")
        #expect(ref.displayIdentity == "app.mood")
        #expect(ref.kindDisplayName == UserDefinedTypeInfo.Kind.enumeration.displayName)
        #expect(ref.userType == type)
        #expect(ref.routine == nil)
        #expect(ref.trigger == nil)
        #expect(ref.suggestedFileName == "app_mood.sql")
    }

    @Test("Sidebar kind and title follow the object kind")
    @MainActor
    func sidebarKind() {
        #expect(DatabaseObjectKind.userType.sidebarObjectKind == .type)
        #expect(SidebarObjectKind.type.category == .type)
        #expect(QueryTabManager.objectSourceTitle(
            for: DatabaseObjectRef(userType: UserDefinedTypeInfo(name: "mood", kind: .enumeration), database: "")
        ).contains("mood"))
    }
}
