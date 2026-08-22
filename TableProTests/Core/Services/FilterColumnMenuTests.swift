//
//  FilterColumnMenuTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Filter Column Menu")
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
        let menu = FilterColumnMenu.build(columns: ["_id", "customer", "items"], fieldPaths: orderPaths)
        #expect(menu.groups.map(\.parent) == ["customer", "items"])
        #expect(menu.groups[0].paths.map(\.path) == ["customer.name", "customer.country"])
        #expect(menu.groups[1].paths.map(\.path) == ["items.sku", "items.price"])
    }

    @Test("a path already present as a flat column is not repeated")
    func skipsExistingColumns() {
        let menu = FilterColumnMenu.build(
            columns: ["customer.name"],
            fieldPaths: [path("customer.name", depth: 2)]
        )
        #expect(menu.groups.isEmpty)
    }

    @Test("top-level paths stay out of the nested section")
    func skipsTopLevelPaths() {
        let menu = FilterColumnMenu.build(columns: ["a"], fieldPaths: [path("a", depth: 1)])
        #expect(menu.groups.isEmpty)
    }

    @Test("paths deeper than the inline limit are left to the searchable picker")
    func depthLimitDefersToPicker() {
        let deep = [path("a.b", depth: 2), path("a.b.c", depth: 3)]
        let menu = FilterColumnMenu.build(columns: ["a"], fieldPaths: deep, depthLimit: 2)
        #expect(menu.groups.flatMap { $0.paths.map(\.path) } == ["a.b"])
        #expect(menu.hasMorePaths)
    }

    @Test("the inline item cap stops the menu growing without bound")
    func itemLimitCapsMenu() {
        let many = (0 ..< 40).map { path("a.f\($0)", depth: 2) }
        let menu = FilterColumnMenu.build(columns: ["a"], fieldPaths: many, itemLimit: 10)
        #expect(menu.groups.flatMap(\.paths).count == 10)
        #expect(menu.hasMorePaths)
    }

    @Test("no nested paths means no overflow affordance")
    func noPathsMeansNoOverflow() {
        let menu = FilterColumnMenu.build(columns: ["a", "b"], fieldPaths: [])
        #expect(menu.groups.isEmpty)
        #expect(!menu.hasMorePaths)
    }

    @Test("membership covers both flat columns and inline nested paths")
    func containsCoversBoth() {
        let menu = FilterColumnMenu.build(columns: ["_id", "items"], fieldPaths: orderPaths)
        #expect(menu.contains("_id"))
        #expect(menu.contains("items.sku"))
        #expect(!menu.contains("items.missing"))
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
