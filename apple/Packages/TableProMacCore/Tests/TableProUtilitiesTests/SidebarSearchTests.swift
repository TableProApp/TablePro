import Foundation
@testable import TableProUtilities
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

    private struct Row {
        let name: String
        let schema: String?

        var path: String { "\(schema ?? "").\(name)" }
    }

    private static let rows = [
        Row(name: "audit_user", schema: "public"),
        Row(name: "users", schema: "public"),
        Row(name: "user", schema: "attendance"),
        Row(name: "user_log", schema: "attendance"),
        Row(name: "timesheet", schema: "attendance"),
        Row(name: "timesheet", schema: "payroll"),
        Row(name: "audit.events", schema: "public"),
        Row(name: "events", schema: "audit"),
        Row(name: "café_orders", schema: nil),
        Row(name: "orders", schema: nil)
    ]

    @Test(
        "One pass keeps the rows and order that filtering then ranking by name gave",
        arguments: ["", "  ", "user", " USER ", "log", "sheet", "cafe", "attendance.", "attendance.user",
                    "tend.sheet", "shop.attendance.time", "audit.events", "shop.", "zzz"]
    )
    func rankedMatchesFilterThenRank(query: String) {
        let search = SidebarSearch(query)
        let admitted = Self.rows.filter { search.matchesObject(named: $0.name, database: "shop", schema: $0.schema) }
        let twoPasses = SidebarNameFilter.ranked(admitted, query: search.nameQuery, name: { $0.name })
        let onePass = search.ranked(Self.rows, name: { $0.name }, database: "shop", schema: { $0.schema })
        #expect(onePass.map(\.path) == twoPasses.map(\.path))
    }

    @Test("Each name is read once per pass, matches included")
    func rankedReadsEachNameOnce() {
        var reads = 0
        let readName = { (row: Row) -> String in
            reads += 1
            return row.name
        }
        let matched = SidebarSearch("user").ranked(Self.rows, name: readName, database: "shop", schema: { $0.schema })
        #expect(matched.map(\.name) == ["user", "users", "user_log", "audit_user"])
        #expect(reads == Self.rows.count)
    }
}
