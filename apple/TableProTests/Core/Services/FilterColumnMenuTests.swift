//
//  FilterColumnMenuTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct FilterColumnMenuTests {
    private func path(_ path: String, depth: Int, arrays: [String] = [], type: String = "VARCHAR") -> PluginFieldPath {
        PluginFieldPath(path: path, typeName: type, depth: depth, arrayPrefixes: arrays)
    }

    private var orderPaths: [PluginFieldPath] {
        [
            path("customer", depth: 1, type: "JSON"),
            path("customer.name", depth: 2),
            path("customer.country", depth: 2),
            path("items", depth: 1, type: "JSON"),
            path("items.sku", depth: 2, arrays: ["items"]),
            path("items.price", depth: 2, arrays: ["items"], type: "FLOAT"),
        ]
    }

    @Test("nested paths group under their top-level parent, in first-seen order")
    func groupsByParent() {
        let menu = FilterColumnMenu.build(columns: ["_id", "customer", "items"], fieldPaths: orderPaths, order: .table)
        #expect(menu.groups.map(\.parent) == ["customer", "items"])
        #expect(menu.groups[0].paths.map(\.path) == ["customer.name", "customer.country"])
        #expect(menu.groups[1].paths.map(\.path) == ["items.sku", "items.price"])
    }

    @Test("a path already present as a flat column is not repeated")
    func skipsExistingColumns() {
        let menu = FilterColumnMenu.build(
            columns: ["customer.name"],
            fieldPaths: [path("customer.name", depth: 2)],
            order: .table
        )
        #expect(menu.groups.isEmpty)
    }

    @Test("top-level paths stay out of the nested section")
    func skipsTopLevelPaths() {
        let menu = FilterColumnMenu.build(columns: ["a"], fieldPaths: [path("a", depth: 1)], order: .table)
        #expect(menu.groups.isEmpty)
    }

    @Test("paths deeper than the inline limit are left to the searchable picker")
    func depthLimitDefersToPicker() {
        let deep = [path("a.b", depth: 2), path("a.b.c", depth: 3)]
        let menu = FilterColumnMenu.build(columns: ["a"], fieldPaths: deep, order: .table, depthLimit: 2)
        #expect(menu.groups.flatMap { $0.paths.map(\.path) } == ["a.b"])
        #expect(menu.hasMorePaths)
    }

    @Test("the inline item cap stops the menu growing without bound")
    func itemLimitCapsMenu() {
        let many = (0 ..< 40).map { path("a.f\($0)", depth: 2) }
        let menu = FilterColumnMenu.build(columns: ["a"], fieldPaths: many, order: .table, itemLimit: 10)
        #expect(menu.groups.flatMap(\.paths).count == 10)
        #expect(menu.hasMorePaths)
    }

    @Test("no nested paths means no overflow affordance")
    func noPathsMeansNoOverflow() {
        let menu = FilterColumnMenu.build(columns: ["a", "b"], fieldPaths: [], order: .table)
        #expect(menu.groups.isEmpty)
        #expect(!menu.hasMorePaths)
    }

    @Test("membership covers both flat columns and inline nested paths")
    func containsCoversBoth() {
        let menu = FilterColumnMenu.build(columns: ["_id", "items"], fieldPaths: orderPaths, order: .table)
        #expect(menu.contains("_id"))
        #expect(menu.contains("items.sku"))
        #expect(!menu.contains("items.missing"))
    }

    // MARK: - Order

    @Test("table order keeps the columns as the table lists them")
    func tableOrderKeepsColumns() {
        let menu = FilterColumnMenu.build(columns: ["id", "zone", "Amount"], fieldPaths: [], order: .table)
        #expect(menu.columns == ["id", "zone", "Amount"])
    }

    @Test("alphabetical order sorts columns the way Finder does")
    func alphabeticalSortsColumns() {
        let menu = FilterColumnMenu.build(
            columns: ["id", "col10", "zone", "Amount", "col2", "émail"],
            fieldPaths: [],
            order: .alphabetical
        )
        #expect(menu.columns == ["Amount", "col2", "col10", "émail", "id", "zone"])
    }

    @Test("names that differ only in case keep one order whatever order they arrive in")
    func alphabeticalOrderIsStableForCaseVariants() {
        let forward = FilterColumnMenu.build(columns: ["name", "Name", "NAME"], fieldPaths: [], order: .alphabetical)
        let reversed = FilterColumnMenu.build(columns: ["NAME", "Name", "name"], fieldPaths: [], order: .alphabetical)
        #expect(forward.columns == reversed.columns)
        #expect(Set(forward.columns) == ["name", "Name", "NAME"])
    }

    @Test("alphabetical order sorts nested groups and the paths inside them")
    func alphabeticalSortsGroups() {
        let menu = FilterColumnMenu.build(columns: ["items", "customer"], fieldPaths: orderPaths, order: .alphabetical)
        #expect(menu.groups.map(\.parent) == ["customer", "items"])
        #expect(menu.groups[0].paths.map(\.path) == ["customer.country", "customer.name"])
        #expect(menu.groups[1].paths.map(\.path) == ["items.price", "items.sku"])
    }

    @Test("the order never changes which paths fit in the menu")
    func orderKeepsInlinePaths() {
        let paths = (0..<12).reversed().map { path("a.f\($0)", depth: 2) }
        let byTable = FilterColumnMenu.build(columns: ["a"], fieldPaths: paths, order: .table, itemLimit: 5)
        let byName = FilterColumnMenu.build(columns: ["a"], fieldPaths: paths, order: .alphabetical, itemLimit: 5)
        #expect(Set(byName.groups.flatMap { $0.paths.map(\.path) }) == Set(byTable.groups.flatMap { $0.paths.map(\.path) }))
        #expect(byName.groups.flatMap { $0.paths.map(\.path) } == ["a.f7", "a.f8", "a.f9", "a.f10", "a.f11"])
    }

    @Test("the cache rebuilds only when the columns, paths or order change")
    @MainActor
    func cacheFollowsInputs() {
        let cache = FilterColumnMenuCache()
        #expect(cache.menu(columns: ["b", "a"], fieldPaths: [], order: .table).columns == ["b", "a"])
        #expect(cache.menu(columns: ["b", "a"], fieldPaths: [], order: .alphabetical).columns == ["a", "b"])
        #expect(cache.menu(columns: ["c", "b", "a"], fieldPaths: [], order: .alphabetical).columns == ["a", "b", "c"])
    }

    // MARK: - Element Scope

    @Test("a path with one array ancestor offers that ancestor as its scope")
    func elementScopeForSingleArray() {
        #expect(FilterColumnMenu.elementScope(for: "items.sku", in: orderPaths) == "items")
    }

    @Test("a path with no array ancestor offers no scope")
    func noElementScopeForObjectPath() {
        #expect(FilterColumnMenu.elementScope(for: "customer.country", in: orderPaths) == nil)
    }

    @Test("a path with two array ancestors offers no scope, because nested $elemMatch is not emitted")
    func noElementScopeForNestedArrays() {
        let nested = [path("orders.items.sku", depth: 3, arrays: ["orders", "orders.items"])]
        #expect(FilterColumnMenu.elementScope(for: "orders.items.sku", in: nested) == nil)
    }

    @Test("an unknown column offers no scope")
    func noElementScopeForUnknownColumn() {
        #expect(FilterColumnMenu.elementScope(for: "nope", in: orderPaths) == nil)
    }

    @Test("the top-level parent is the segment before the first dot")
    func topLevelParent() {
        #expect(FilterColumnMenu.topLevelParent(of: "customer.address.city") == "customer")
        #expect(FilterColumnMenu.topLevelParent(of: "plain") == "plain")
    }
}
