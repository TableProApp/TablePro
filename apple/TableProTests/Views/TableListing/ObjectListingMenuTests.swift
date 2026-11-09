//
//  ObjectListingMenuTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct ObjectListingMenuTests {
    private let orders = ObjectListingItem.relation(name: "orders", schema: "sales", type: .table)
    private let recent = ObjectListingItem.relation(name: "recent_orders", schema: "sales", type: .view)
    private let touch = ObjectListingItem.sourced(DatabaseObjectRef(kind: .function, name: "touch", database: "shop", schema: "sales"))
    private let mood = ObjectListingItem.sourced(DatabaseObjectRef(kind: .userType, name: "mood", database: "shop", schema: "sales"))

    private func titles(_ commands: [ObjectListingMenuCommand]) -> [String] {
        commands.map(\.title)
    }

    @Test("A double click opens a relation and shows the source of anything else")
    func primaryActionFollowsTheKind() {
        #expect(ObjectListingMenu.primaryAction(for: orders) == .open(orders))
        #expect(ObjectListingMenu.primaryAction(for: touch) == .showSource(touch))
    }

    @Test("A table offers what the sidebar offers it: a new tab, its structure and its name")
    func tableCommands() {
        let commands = ObjectListingMenu.commands(clicked: orders, targets: [orders])

        #expect(commands.map(\.action) == [.openInNewTab(orders), .showStructure(orders), .copyNames(["orders"])])
        #expect(titles(commands) == [
            String(localized: "Open in New Tab"), String(localized: "Show Structure"), String(localized: "Copy Name"),
        ])
    }

    @Test("A view adds Show DDL, which a table has on its Structure tab instead")
    func viewAddsShowDDL() {
        let commands = ObjectListingMenu.commands(clicked: recent, targets: [recent])

        #expect(commands.map(\.action).contains(.showSource(recent)))
        #expect(titles(commands).contains(String(localized: "Show DDL")))
    }

    @Test("A routine offers its DDL and its name; a type calls its source a definition, as the sidebar does")
    func sourcedCommands() {
        #expect(titles(ObjectListingMenu.commands(clicked: touch, targets: [touch])) == [
            String(localized: "Show DDL"), String(localized: "Copy Name"),
        ])
        #expect(titles(ObjectListingMenu.commands(clicked: mood, targets: [mood])) == [
            String(localized: "Show Definition"), String(localized: "Copy Name"),
        ])
    }

    @Test("Copy Name copies every row the menu acts on; the other commands act on the clicked row")
    func copyNamesCoversTheSelection() {
        let commands = ObjectListingMenu.commands(clicked: orders, targets: [orders, recent])

        #expect(commands.first?.action == .openInNewTab(orders))
        #expect(commands.last == ObjectListingMenuCommand(
            title: String(format: String(localized: "Copy %lld Names"), 2),
            action: .copyNames(["orders", "recent_orders"])
        ))
    }
}
