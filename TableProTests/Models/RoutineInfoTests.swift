//
//  RoutineInfoTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("RoutineInfo Identity")
struct RoutineInfoTests {
    @Test("Overloaded functions with different signatures get distinct ids")
    func overloadsAreDistinct() {
        let a = RoutineInfo(name: "st_distance", schema: "public", kind: .function, signature: "(geometry, geometry)")
        let b = RoutineInfo(name: "st_distance", schema: "public", kind: .function, signature: "(geography, geography)")

        #expect(a.id != b.id)
        #expect(Set([a.id, b.id]).count == 2)
    }

    @Test("Same routine yields a stable id")
    func sameRoutineStableId() {
        let a = RoutineInfo(name: "f", schema: "public", kind: .function, signature: "(int)")
        let b = RoutineInfo(name: "f", schema: "public", kind: .function, signature: "(int)")
        #expect(a.id == b.id)
    }

    @Test("Procedure and function with the same name get distinct ids")
    func procedureAndFunctionDistinct() {
        let proc = RoutineInfo(name: "sync", schema: "public", kind: .procedure, signature: nil)
        let fn = RoutineInfo(name: "sync", schema: "public", kind: .function, signature: nil)
        #expect(proc.id != fn.id)
    }

    @Test("Signatureless routine falls back to name-based id")
    func signaturelessFallback() {
        let routine = RoutineInfo(name: "do_thing", schema: "app", kind: .procedure, signature: nil)
        #expect(routine.id == "PROCEDURE_app.do_thing")
    }
}
