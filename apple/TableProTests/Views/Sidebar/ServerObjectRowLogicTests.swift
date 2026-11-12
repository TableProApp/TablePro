//
//  ServerObjectRowLogicTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ServerObjectRowLogicTests {
    private let events = SidebarServerObjectKind(
        id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar.badge.clock", scope: .container
    )
    private let extensions = SidebarServerObjectKind(
        id: "extension", displayName: "Extension", pluralDisplayName: "Extensions", iconName: "puzzlepiece.extension",
        scope: .database
    )

    private func event(enabled: Bool?, status: String) -> ServerObjectInfo {
        ServerObjectInfo(
            kindId: "event", name: "nightly", schema: "shop", detail: "Recurring", isEnabled: enabled,
            attributes: [ObjectAttribute(label: "Status", value: status), ObjectAttribute(label: "Schedule", value: "EVERY 1 DAY")]
        )
    }

    @Test("The tooltip names the state once, in the driver's own words")
    func tooltipNamesStateOnce() {
        let tooltip = ServerObjectRowLogic.tooltip(for: event(enabled: false, status: "Disabled on Replica"), kind: events)

        #expect(tooltip == "shop.nightly\nRecurring\nStatus: Disabled on Replica\nSchedule: EVERY 1 DAY")
    }

    @Test("A database-wide object's tooltip opens with its bare name")
    func databaseScopedTooltipIsBare() {
        let object = ServerObjectInfo(
            kindId: "extension", name: "pgcrypto", schema: "public", identity: "16384", detail: "1.3",
            attributes: [ObjectAttribute(label: "Schema", value: "public")]
        )

        #expect(ServerObjectRowLogic.tooltip(for: object, kind: extensions) == "pgcrypto\n1.3\nSchema: public")
        #expect(ServerObjectRowLogic.displayName(for: object, kind: extensions) == "pgcrypto")
        #expect(ServerObjectRowLogic.displayName(for: event(enabled: true, status: "Enabled"), kind: events) == "shop.nightly")
    }

    @Test("The accessibility label reads kind, name and detail")
    func accessibilityLabel() {
        let label = ServerObjectRowLogic.accessibilityLabel(for: event(enabled: true, status: "Enabled"), kind: events)
        #expect(label == String(format: String(localized: "%1$@: %2$@"), "Event", "nightly") + ", Recurring")
    }

    // `ServerObjectInfo` is equal by id, so a row holding it would not redraw a new version or state.
    @Test("A refreshed object with the same id hands the row new drawn values")
    func refreshedObjectChangesTheDrawnValues() {
        let before = ServerObjectInfo(kindId: "extension", name: "pgcrypto", schema: "public", identity: "16384", detail: "1.3")
        let after = ServerObjectInfo(kindId: "extension", name: "pgcrypto", schema: "public", identity: "16384", detail: "1.4")
        #expect(before == after)

        let oldRow = ServerObjectRowView(object: before, kind: extensions)
        let newRow = ServerObjectRowView(object: after, kind: extensions)

        #expect(oldRow.detail == "1.3")
        #expect(newRow.detail == "1.4")
        #expect(oldRow.tooltip != newRow.tooltip)
        #expect(newRow.iconName == "puzzlepiece.extension")
    }
}
