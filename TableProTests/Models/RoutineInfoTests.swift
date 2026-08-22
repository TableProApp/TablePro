//
//  RoutineInfoTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("RoutineInfo Identity")
struct RoutineInfoTests {
    @Test("Overloaded functions with different argument signatures get distinct ids")
    func overloadsAreDistinct() {
        let a = RoutineInfo(name: "st_distance", kind: .function, schema: "public", argumentSignature: "(geometry, geometry)")
        let b = RoutineInfo(name: "st_distance", kind: .function, schema: "public", argumentSignature: "(geography, geography)")

        #expect(a.id != b.id)
        #expect(Set([a.id, b.id]).count == 2)
    }

    /// The exact case that used to lose a routine: two overloads that return the same type. The id
    /// discriminator was the return type, so both produced one id and the tree dropped one of them.
    @Test("Overloads that return the same type both survive a Set")
    func overloadsWithSameReturnTypeBothSurvive() {
        let a = RoutineInfo(
            name: "f", kind: .function, schema: "public",
            argumentSignature: "(integer)", returnType: "integer"
        )
        let b = RoutineInfo(
            name: "f", kind: .function, schema: "public",
            argumentSignature: "(text)", returnType: "integer"
        )

        #expect(a != b)
        #expect(Set([a, b]).count == 2)
        #expect(Dictionary(grouping: [a, b], by: \.id).count == 2)
    }

    /// The driver's own key wins over the readable signature, because two engines can spell one
    /// argument list two ways while the oid is the same object either way.
    @Test("Driver identity separates routines whose signatures agree")
    func identityWinsOverSignature() {
        let a = RoutineInfo(name: "f", kind: .function, schema: "public", argumentSignature: "()", identity: "16401")
        let b = RoutineInfo(name: "f", kind: .function, schema: "public", argumentSignature: "()", identity: "16402")
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("Same routine yields a stable id")
    func sameRoutineStableId() {
        let a = RoutineInfo(name: "f", kind: .function, schema: "public", argumentSignature: "(int)")
        let b = RoutineInfo(name: "f", kind: .function, schema: "public", argumentSignature: "(int)")
        #expect(a.id == b.id)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Procedure and function with the same name get distinct ids")
    func procedureAndFunctionDistinct() {
        let proc = RoutineInfo(name: "sync", kind: .procedure, schema: "public")
        let fn = RoutineInfo(name: "sync", kind: .function, schema: "public")
        #expect(proc.id != fn.id)
    }

    @Test("Signatureless routine falls back to name-based id")
    func signaturelessFallback() {
        let routine = RoutineInfo(name: "do_thing", kind: .procedure, schema: "app")
        #expect(routine.id == "PROCEDURE_app.do_thing")
    }

    @Test("Return type is never used as the overload discriminator")
    func returnTypeIsNotADiscriminator() {
        let a = RoutineInfo(name: "f", kind: .function, schema: "public", returnType: "integer")
        let b = RoutineInfo(name: "f", kind: .function, schema: "public", returnType: "text")
        #expect(a.id == b.id)
    }
}

@Suite("TriggerInfo Identity")
struct TriggerInfoTests {
    /// A trigger name is unique per table on PostgreSQL and Oracle, so a database-wide list keyed
    /// on the name alone loses one of any two tables that agree on it.
    @Test("Same trigger name on two tables stays two triggers")
    func sameNameDifferentTables() {
        let a = TriggerInfo(
            name: "audit", timing: "AFTER", event: "INSERT", statement: "",
            table: "orders", schema: "public"
        )
        let b = TriggerInfo(
            name: "audit", timing: "AFTER", event: "INSERT", statement: "",
            table: "customers", schema: "public"
        )
        #expect(a.id != b.id)
        #expect(Set([a.id, b.id]).count == 2)
    }

    @Test("Id is schema-qualified when a schema is known")
    func qualifiedId() {
        let trigger = TriggerInfo(
            name: "audit", timing: "AFTER", event: "INSERT", statement: "",
            table: "orders", schema: "public"
        )
        #expect(trigger.id == "public.orders.audit")
        #expect(trigger.qualifiedName == "orders.audit")
    }

    @Test("A trigger with no table falls back to its name")
    func tablelessFallback() {
        let trigger = TriggerInfo(name: "audit", timing: "AFTER", event: "INSERT", statement: "")
        #expect(trigger.id == "audit")
        #expect(trigger.qualifiedName == "audit")
    }
}

@Suite("RoutineDisplayLabel")
struct RoutineDisplayLabelTests {
    @Test("A unique name shows without its signature")
    func uniqueNameIsBare() {
        let routines = [
            RoutineInfo(name: "calculate_age", kind: .function, schema: "public", argumentSignature: "(date)"),
            RoutineInfo(name: "sync_orders", kind: .procedure, schema: "public", argumentSignature: "()")
        ]
        let labels = RoutineDisplayLabel.labels(for: routines)
        #expect(labels[routines[0].id] == "calculate_age")
        #expect(labels[routines[1].id] == "sync_orders")
    }

    @Test("A repeated name shows every row with its signature")
    func repeatedNameIsQualified() {
        let routines = [
            RoutineInfo(name: "transform", kind: .function, schema: "public", argumentSignature: "(geometry, integer)"),
            RoutineInfo(name: "transform", kind: .function, schema: "public", argumentSignature: "(geometry, text)"),
            RoutineInfo(name: "other", kind: .function, schema: "public", argumentSignature: "(int)")
        ]
        let labels = RoutineDisplayLabel.labels(for: routines)
        #expect(labels[routines[0].id] == "transform(geometry, integer)")
        #expect(labels[routines[1].id] == "transform(geometry, text)")
        #expect(labels[routines[2].id] == "other")
    }

    @Test("A repeated name with no signature still falls back to the bare name")
    func repeatedNameWithoutSignature() {
        let routines = [
            RoutineInfo(name: "f", kind: .function, schema: "a"),
            RoutineInfo(name: "f", kind: .function, schema: "b")
        ]
        let labels = RoutineDisplayLabel.labels(for: routines)
        #expect(labels[routines[0].id] == "f")
        #expect(labels[routines[1].id] == "f")
    }

    @Test("Copy with Signature qualifies the name and keeps the parentheses")
    func copyableSignatureIsQualified() {
        let routine = RoutineInfo(
            name: "calculate_age", kind: .function, schema: "public",
            argumentSignature: "(date)", returnType: "integer"
        )
        #expect(RoutineDisplayLabel.copyableSignature(for: routine) == "public.calculate_age(date)")
    }

    @Test("Copy with Signature falls back to the qualified name alone")
    func copyableSignatureWithoutArguments() {
        let routine = RoutineInfo(name: "sync", kind: .procedure, schema: "app")
        #expect(RoutineDisplayLabel.copyableSignature(for: routine) == "app.sync")
    }
}
