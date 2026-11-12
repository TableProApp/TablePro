//
//  MySQLEventServerObjectTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLEventServerObjectTests {
    private func row(_ cells: String?...) -> [PluginCellValue] {
        cells.map(PluginCellValue.fromOptional)
    }

    private func attribute(_ object: PluginServerObjectInfo?, _ label: String) -> String? {
        object?.attributes.first { $0.label == label }?.value
    }

    @Test("MySQL and MariaDB declare Events; the other flavors sharing the driver declare none")
    func kindsPerFlavor() {
        #expect(MySQLEvents.isDeclared(flavor: .mysql, banner: "8.0.36"))
        #expect(MySQLEvents.isDeclared(flavor: .mariadb, banner: "10.11.6-MariaDB"))
        #expect(MySQLEvents.isDeclared(flavor: .mysql, banner: nil))
        #expect(!MySQLEvents.isDeclared(flavor: .tidb(version: nil), banner: "8.0.11-TiDB-v7.5.0"))
        #expect(!MySQLEvents.isDeclared(flavor: .databend, banner: nil))
        #expect(!MySQLEvents.isDeclared(flavor: .oceanbase(version: nil), banner: nil))
        #expect(!MySQLEvents.isDeclared(flavor: .starrocks, banner: nil))
    }

    @Test("A server older than 5.1.6 has no events catalog and declares no Events")
    func kindsFollowTheEventsFloor() {
        #expect(!MySQLEvents.isDeclared(flavor: .mysql, banner: "5.0.96-log"))
        #expect(!MySQLEvents.isDeclared(flavor: .mysql, banner: "4.1.22-standard"))
        #expect(MySQLEvents.isDeclared(flavor: .mysql, banner: "5.1.6"))
    }

    @Test("The Events kind is listed per database, under its own symbol")
    func eventKindDescriptor() {
        let kind = MySQLEvents.kind
        #expect(kind.id == "event")
        #expect(kind.scope == .container)
        #expect(kind.iconName == "calendar.badge.clock")
        #expect(kind.pluralDisplayName == String(localized: "Events"))
    }

    @Test("A recurring event reads its interval as the schedule and counts as enabled")
    func recurringEvent() {
        let object = MySQLEventRows.object(
            from: row(
                "nightly_cleanup", "RECURRING", "ENABLED", "shop",
                nil, "1", "DAY", "2026-01-01 03:00:00", nil,
                "PRESERVE", "2026-11-10 03:00:00", "app@%", "Purges the log"
            ),
            scheduler: "ON"
        )

        #expect(object?.kindId == "event")
        #expect(object?.name == "nightly_cleanup")
        #expect(object?.schema == "shop")
        #expect(object?.identity == nil)
        #expect(object?.detail == String(localized: "Recurring"))
        #expect(object?.isEnabled == true)
        #expect(attribute(object, String(localized: "Schedule")) == "EVERY 1 DAY")
        #expect(attribute(object, String(localized: "Status")) == String(localized: "Enabled"))
        #expect(attribute(object, String(localized: "Starts")) == "2026-01-01 03:00:00")
        #expect(attribute(object, String(localized: "Ends")) == nil)
        #expect(attribute(object, String(localized: "On Completion")) == "PRESERVE")
        #expect(attribute(object, String(localized: "Last Executed")) == "2026-11-10 03:00:00")
        #expect(attribute(object, String(localized: "Definer")) == "app@%")
        #expect(attribute(object, String(localized: "Comment")) == "Purges the log")
        #expect(attribute(object, String(localized: "Event Scheduler")) == "ON")
    }

    @Test("A one-time event reads its run time as the schedule")
    func oneTimeEvent() {
        let object = MySQLEventRows.object(
            from: row(
                "close_quarter", "ONE TIME", "DISABLED", "shop",
                "2026-12-31 23:59:00", nil, nil, nil, nil,
                "NOT PRESERVE", nil, "root@localhost", nil
            ),
            scheduler: "OFF"
        )

        #expect(object?.detail == String(localized: "One Time"))
        #expect(object?.isEnabled == false)
        #expect(attribute(object, String(localized: "Schedule")) == "AT '2026-12-31 23:59:00'")
        #expect(attribute(object, String(localized: "Status")) == String(localized: "Disabled"))
        #expect(attribute(object, String(localized: "Last Executed")) == nil)
        #expect(attribute(object, String(localized: "Event Scheduler")) == "OFF")
    }

    @Test("An event disabled on a replica says so under both spellings the server has used")
    func replicaDisabledEvent() {
        for status in ["SLAVESIDE_DISABLED", "REPLICA_SIDE_DISABLED"] {
            let object = MySQLEventRows.object(from: row(
                "sync_totals", "RECURRING", status, "shop", nil, "1", "HOUR", nil, nil, "PRESERVE", nil, nil, nil
            ))
            #expect(object?.isEnabled == false, "\(status)")
            #expect(attribute(object, String(localized: "Status")) == String(localized: "Disabled on Replica"), "\(status)")
        }
    }

    @Test("A composite interval is quoted the way CREATE EVENT spells it")
    func compositeInterval() {
        #expect(MySQLEventRows.schedule(isRecurring: true, executeAt: nil, intervalValue: "1:30", intervalField: "HOUR_MINUTE")
            == "EVERY '1:30' HOUR_MINUTE")
        #expect(MySQLEventRows.schedule(isRecurring: true, executeAt: nil, intervalValue: nil, intervalField: "DAY") == nil)
        #expect(MySQLEventRows.schedule(isRecurring: false, executeAt: nil, intervalValue: "1", intervalField: "DAY") == nil)
    }

    @Test("A scheduler the server would not report leaves only that attribute out")
    func missingSchedulerDropsOneAttribute() {
        let object = MySQLEventRows.object(from: row(
            "nightly", "RECURRING", "ENABLED", "shop", nil, "1", "DAY", nil, nil, "PRESERVE", nil, "app@%", nil
        ))

        #expect(attribute(object, String(localized: "Event Scheduler")) == nil)
        #expect(attribute(object, String(localized: "Schedule")) == "EVERY 1 DAY")
        #expect(attribute(object, String(localized: "Definer")) == "app@%")
    }

    @Test("A re-read picks the row spelled exactly as the tab names it")
    func rereadPicksTheExactSpelling() {
        let rows = [row("Nightly", "RECURRING", "ENABLED", "shop"), row("nightly", "ONE TIME", "DISABLED", "shop")]

        #expect(MySQLEventRows.row(named: "nightly", in: rows)?.first == PluginCellValue.fromOptional("nightly"))
        #expect(MySQLEventRows.row(named: "NIGHTLY", in: rows)?.first == PluginCellValue.fromOptional("Nightly"))
        #expect(MySQLEventRows.row(named: "nightly", in: []) == nil)
    }

    @Test("Four columns alone still map, and a row with no name is dropped")
    func shortAndNamelessRows() {
        let objects = MySQLEventRows.objects(from: [
            row("legacy", "RECURRING", "ENABLED", "shop"),
            row(nil, "RECURRING", "ENABLED", "shop")
        ])

        #expect(objects.count == 1)
        #expect(objects.first?.name == "legacy")
        #expect(objects.first?.isEnabled == true)
        #expect(attribute(objects.first, String(localized: "Schedule")) == nil)
    }
}
