//
//  SidebarSearchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SidebarSearchTests {
    @Test("A plain search admits every container and matches names")
    func plainSearch() {
        let search = SidebarSearch("sheet")
        #expect(search.qualified == nil)
        #expect(search.admits(database: "shop", schema: "attendance"))
        #expect(search.matchesName("timesheet"))
        #expect(!search.matchesName("orders"))
    }

    @Test("A plain search matches a container by its own name")
    func plainContainerName() {
        let search = SidebarSearch("attend")
        #expect(search.matchesContainer(database: "shop", schema: "attendance"))
        #expect(!search.matchesContainer(database: "shop", schema: "public"))
    }

    @Test("A qualified search admits only the container it names")
    func qualifiedAdmits() {
        let search = SidebarSearch("attendance.time")
        #expect(search.admits(database: "shop", schema: "attendance"))
        #expect(!search.admits(database: "shop", schema: "public"))
        #expect(search.nameQuery == "time")
        #expect(search.matchesName("timesheet"))
    }

    @Test("A qualified search matches its container by substring, like the plain filter")
    func qualifiedSubstring() {
        #expect(SidebarSearch("tend.sheet").admits(database: nil, schema: "attendance"))
        #expect(!SidebarSearch("atd.sheet").admits(database: nil, schema: "attendance"))
    }

    @Test("A trailing dot matches the container and every name in it")
    func trailingDot() {
        let search = SidebarSearch("attendance.")
        #expect(search.matchesContainer(database: "shop", schema: "attendance"))
        #expect(search.matchesName("anything"))
    }

    @Test("A qualified search with a name does not match the container by itself")
    func namedQueryDoesNotMatchContainer() {
        #expect(!SidebarSearch("attendance.time").matchesContainer(database: "shop", schema: "attendance"))
    }

    @Test("A database, a schema and a name need both containers to match")
    func threeParts() {
        let search = SidebarSearch("shop.attendance.time")
        #expect(search.admits(database: "shop", schema: "attendance"))
        #expect(!search.admits(database: "other", schema: "attendance"))
        #expect(!search.admits(database: nil, schema: "attendance"))
    }

    @Test("A name that holds a dot matches its own text anywhere")
    func literalDottedName() {
        let search = SidebarSearch("audit.events")
        #expect(search.matchesObject(named: "audit.events", database: "shop", schema: "public"))
        #expect(search.matchesObject(named: "events", database: "shop", schema: "audit"))
        #expect(!search.matchesObject(named: "events", database: "shop", schema: "public"))
    }

    @Test("A plain search matches objects by name alone")
    func plainObjectMatch() {
        let search = SidebarSearch("sheet")
        #expect(search.matchesObject(named: "timesheet", database: "shop", schema: "attendance"))
        #expect(!search.matchesObject(named: "orders", database: "shop", schema: "attendance"))
    }

    @Test("On an engine with no schemas the container is the database")
    func schemaLessEngine() {
        let search = SidebarSearch("shop.orders")
        #expect(search.admits(database: "shop", schema: nil))
        #expect(!search.admits(database: "blog", schema: nil))
    }
}
