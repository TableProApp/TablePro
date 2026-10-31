//
//  StructureListGridAccessibilityTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class MountedStructureList {
    let window: NSWindow
    let controller: DataGridViewController
    let list: StructureListGridModel<String>

    init(columns: [String], rows: [StructureListRow<String>]) {
        list = StructureListGridModel<String>()
        list.load(
            columns: columns,
            rows: rows,
            defaultWidths: Array(repeating: 100, count: columns.count),
            minimumWidths: [],
            databaseType: .mysql,
            sortState: nil
        )
        controller = DataGridViewController(model: list.model)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
    }

    var table: DataGridTableView { controller.main.tableView }

    func cell(row: Int, dataColumn: Int) throws -> DataGridAccessibilityCellView {
        let columns = list.model.columns
        let position = try #require(columns.displayPosition(ofDataIndex: dataColumn))
        let index = try #require(controller.main.tableIndex(forDisplayPosition: position, columns: columns))
        return try #require(table.view(atColumn: index, row: row, makeIfNecessary: true) as? DataGridAccessibilityCellView)
    }

    func spoken(row: Int, dataColumn: Int) throws -> String? {
        try cell(row: row, dataColumn: dataColumn).accessibilityValue() as? String
    }

    func drawn(row: Int, dataColumn: Int) -> String? {
        let model = list.model
        guard let rowModel = model.row(at: row),
              let column = model.columns.columns.first(where: { $0.dataIndex == dataColumn }),
              let pass = controller.presenter.makePass(in: table.effectiveAppearance) else { return nil }
        return controller.presenter.appearance(
            of: rowModel,
            displayRow: row,
            column: column,
            visualState: controller.presenter.visualState(of: rowModel),
            pass: pass,
            onEmphasizedSelection: false
        )?.text
    }

    func tearDown() {
        controller.dismantle()
        window.contentView = nil
    }
}

@MainActor
struct StructureListGridAccessibilityTests {
    @Test("The Enabled column draws YES and NO and reads Enabled and Disabled")
    func triggerEnabledIsSpoken() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let triggers = [
            TriggerInfo(name: "trg_on", timing: "BEFORE", event: "UPDATE", statement: "", enabled: true),
            TriggerInfo(name: "trg_off", timing: "AFTER", event: "INSERT", statement: "", enabled: false),
        ]
        let rows = triggers.map { trigger in
            StructureListRow(
                id: trigger.id,
                values: TriggerListColumns.values(for: trigger, showsEnabled: true),
                spokenValues: TriggerListColumns.spokenValues(for: trigger, showsEnabled: true)
            )
        }
        let grid = MountedStructureList(columns: TriggerListColumns.titles(showsEnabled: true), rows: rows)
        defer { grid.tearDown() }
        let enabled = TriggerListColumns.enabledColumn

        #expect(grid.drawn(row: 0, dataColumn: enabled) == "YES")
        #expect(grid.drawn(row: 1, dataColumn: enabled) == "NO")
        #expect(try grid.spoken(row: 0, dataColumn: enabled) == String(localized: "Enabled"))
        #expect(try grid.spoken(row: 1, dataColumn: enabled) == String(localized: "Disabled"))
        #expect(try grid.cell(row: 1, dataColumn: enabled).accessibilityLabel() == String(
            format: String(localized: "Row %d, column %d: %@"), 2, enabled + 1, String(localized: "Disabled")
        ))
        #expect(try grid.spoken(row: 0, dataColumn: TriggerListColumns.nameColumn) == "trg_on")
    }

    @Test("The Active column draws YES and NO and reads Active and Inactive")
    func partActiveIsSpoken() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let parts = [true, false].map { active in
            ClickHousePartInfo(
                partition: "202601", name: "p", rows: 1, bytesOnDisk: 1, modificationTime: "", active: active
            )
        }
        let rows = parts.map { part in
            let row = ClickHousePartsView.gridRow(for: part)
            return StructureListRow(id: part.id.uuidString, values: row.values, spokenValues: row.spokenValues)
        }
        let grid = MountedStructureList(columns: ClickHousePartsView.columnTitles, rows: rows)
        defer { grid.tearDown() }
        let active = ClickHousePartsView.activeColumn

        #expect(grid.drawn(row: 0, dataColumn: active) == "YES")
        #expect(try grid.spoken(row: 0, dataColumn: active) == String(localized: "Active"))
        #expect(try grid.spoken(row: 1, dataColumn: active) == String(localized: "Inactive"))
        #expect(try grid.spoken(row: 0, dataColumn: 0) == "202601")
    }

    @Test("A cell with no spoken value reads the text it draws")
    func unspokenCellReadsItsText() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let grid = MountedStructureList(
            columns: ["Name", "Unique"],
            rows: [StructureListRow(id: "idx", values: ["idx_name", "YES"])]
        )
        defer { grid.tearDown() }
        let rowID = try #require(grid.list.model.rowID(at: 0))
        let unique = try #require(grid.list.model.columns.column(at: 1))

        #expect(try grid.spoken(row: 0, dataColumn: 1) == "YES")
        #expect(grid.list.grid.gridAccessibilityText(for: rowID, column: unique) == nil)
    }

    // Each list names its grid for VoiceOver ("Triggers"), where an unnamed one reads "Data grid".
    @Test("The trigger list's grid is named for the list it shows")
    func namesTheGrid() async throws {
        let window = ThemeTestFixture.host(
            TriggerListPane(
                triggers: [TriggerInfo(name: "trg", timing: "BEFORE", event: "UPDATE", statement: "")],
                databaseType: .mysql,
                state: TriggerInspectorState()
            ),
            size: NSSize(width: 600, height: 240)
        )
        defer { window.contentView = nil }
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        let table = try #require(Self.mainTable(in: window.contentView))

        #expect(table.accessibilityLabel() == StructurePane.triggers.displayName)
    }

    private static func mainTable(in view: NSView?) -> DataGridTableView? {
        guard let view else { return nil }
        if let table = view as? DataGridTableView, table.paneKind == .main { return table }
        return view.subviews.lazy.compactMap { mainTable(in: $0) }.first
    }
}
