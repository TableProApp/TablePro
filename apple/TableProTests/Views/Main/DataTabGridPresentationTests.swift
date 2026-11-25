//
//  DataTabGridPresentationTests.swift
//  TableProTests
//
//  onChange runs the closure of the body from before a tab switch, so a write that captured the model gave the
//  incoming tab's configuration to the outgoing tab's model.
//

import AppKit
import SwiftUI
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct DataTabGridPresentationTests {
    private let fixtures = CoordinatorFixtures()

    private static let rows = TableRows.from(
        queryRows: [[.text("1"), .text("paid")], [.text("2"), .text("late")]],
        columns: ["id", "status"],
        columnTypes: [.text(rawType: nil), .text(rawType: nil)]
    )

    private static let paid = HighlightRule(columnName: "status", value: "paid", color: .green)
    private static let late = HighlightRule(columnName: "status", value: "late", color: .red)

    private func addTab(
        _ fixture: CoordinatorFixture,
        named name: String,
        primaryKey: String,
        rules: [HighlightRule] = [],
        select: Bool = false
    ) -> QueryTab {
        var tab = QueryTab(title: name, tabType: .query)
        tab.tableContext.primaryKeyColumns = [primaryKey]
        tab.sessionHighlightRules = rules
        return fixture.addTab(tab, rows: Self.rows, select: select)
    }

    private func tab(_ id: UUID, in fixture: CoordinatorFixture) throws -> QueryTab {
        try #require(fixture.tabManager.tabs.first { $0.id == id })
    }

    private func mount(_ model: DataGridModel) -> DataTabGridMountStub {
        let stub = DataTabGridMountStub()
        model.attach(stub)
        return stub
    }

    private func repaints(_ stub: DataTabGridMountStub) -> Int {
        stub.changes.filter { $0 == .allRowsRepainted }.count
    }

    // MARK: - Applying

    @Test("Applying tab B's presentation reaches only B's model")
    func presentationReachesOnlyItsTab() throws {
        let fixture = fixtures.make()
        let first = addTab(fixture, named: "A", primaryKey: "id", select: true)
        let second = addTab(fixture, named: "B", primaryKey: "code")
        let firstModel = fixture.coordinator.gridModel(forTab: first.id)
        let secondModel = fixture.coordinator.gridModel(forTab: second.id)
        let before = firstModel.configuration

        fixture.tabManager.selectedTabId = second.id
        fixture.coordinator.applyGridPresentation(fixture.coordinator.gridPresentation(for: try tab(second.id, in: fixture)))

        #expect(firstModel.configuration == before)
        #expect(firstModel.configuration.primaryKeyColumns == ["id"])
        #expect(secondModel.configuration.primaryKeyColumns == ["code"])
    }

    @Test("Switching between tabs with the same rules never clears or repaints either model's highlights")
    func equalRulesNeverRepaint() throws {
        let fixture = fixtures.make()
        let first = addTab(fixture, named: "A", primaryKey: "id", rules: [Self.paid], select: true)
        let second = addTab(fixture, named: "B", primaryKey: "id", rules: [Self.paid])
        let coordinator = fixture.coordinator
        let firstModel = coordinator.gridModel(forTab: first.id)
        let secondModel = coordinator.gridModel(forTab: second.id)
        let firstMount = mount(firstModel)
        let secondMount = mount(secondModel)
        let highlight = RowHighlight(rowRule: Self.paid, cellRules: [:])
        firstModel.display.cache.setHighlight(highlight, forID: .existing(0))
        secondModel.display.cache.setHighlight(highlight, forID: .existing(0))

        for id in [second.id, first.id, second.id] {
            fixture.tabManager.selectedTabId = id
            coordinator.applyGridPresentation(coordinator.gridPresentation(for: try tab(id, in: fixture)))
        }

        #expect(repaints(firstMount) == 0)
        #expect(repaints(secondMount) == 0)
        #expect(firstModel.display.cache.highlight(forID: .existing(0)) == highlight)
        #expect(secondModel.display.cache.highlight(forID: .existing(0)) == highlight)
    }

    @Test("A rules change on the shown tab clears and repaints its highlights once")
    func rulesChangeRepaintsOnce() throws {
        let fixture = fixtures.make()
        let shown = addTab(fixture, named: "A", primaryKey: "id", rules: [Self.paid], select: true)
        let coordinator = fixture.coordinator
        let model = coordinator.gridModel(forTab: shown.id)
        let stub = mount(model)
        model.display.cache.setHighlight(RowHighlight(rowRule: Self.paid, cellRules: [:]), forID: .existing(0))

        coordinator.setHighlightRules([Self.paid, Self.late], forTab: shown.id)
        let presentation = coordinator.gridPresentation(for: try tab(shown.id, in: fixture))
        coordinator.applyGridPresentation(presentation)
        coordinator.applyGridPresentation(presentation)

        #expect(repaints(stub) == 1)
        #expect(model.display.cache.highlight(forID: .existing(0)) == nil)
    }

    @Test("Rules changed while a tab was hidden clear its highlights when it is shown")
    func rulesChangedWhileHiddenApplyOnReturn() throws {
        let fixture = fixtures.make()
        let first = addTab(fixture, named: "A", primaryKey: "id", rules: [Self.paid], select: true)
        let second = addTab(fixture, named: "B", primaryKey: "id", rules: [Self.paid])
        let coordinator = fixture.coordinator
        let secondModel = coordinator.gridModel(forTab: second.id)
        let secondMount = mount(secondModel)
        secondModel.display.cache.setHighlight(RowHighlight(rowRule: Self.paid, cellRules: [:]), forID: .existing(0))
        coordinator.applyGridPresentation(coordinator.gridPresentation(for: try tab(first.id, in: fixture)))

        coordinator.setHighlightRules([Self.late], forTab: second.id)
        #expect(repaints(secondMount) == 0)

        fixture.tabManager.selectedTabId = second.id
        coordinator.applyGridPresentation(coordinator.gridPresentation(for: try tab(second.id, in: fixture)))

        #expect(repaints(secondMount) == 1)
        #expect(secondModel.display.cache.highlight(forID: .existing(0)) == nil)
    }

    // MARK: - Hosted switch

    @Test("Switching the hosted grid from A to B and back leaves each model with its own configuration")
    func hostedSwitchKeepsEachModelsConfiguration() async throws {
        let fixture = fixtures.make()
        let first = addTab(fixture, named: "A", primaryKey: "id", select: true)
        let second = addTab(fixture, named: "B", primaryKey: "code")
        let coordinator = fixture.coordinator
        let firstModel = coordinator.gridModel(forTab: first.id)
        let secondModel = coordinator.gridModel(forTab: second.id)
        // One view type throughout, so SwiftUI updates the grid in place the way the data tab's body does.
        func grid(_ id: UUID) throws -> AnyView {
            AnyView(DataTabGrid(
                coordinator: coordinator,
                model: coordinator.gridModel(forTab: id),
                presentation: coordinator.gridPresentation(for: try tab(id, in: fixture))
            ))
        }
        let host = NSHostingView(rootView: try grid(first.id))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = GridTestWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return firstModel.isMounted
        }
        #expect(firstModel.configuration.primaryKeyColumns == ["id"])

        fixture.tabManager.selectedTabId = second.id
        host.rootView = try grid(second.id)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return secondModel.isMounted
        }

        #expect(firstModel.configuration.primaryKeyColumns == ["id"])
        #expect(secondModel.configuration.primaryKeyColumns == ["code"])

        fixture.tabManager.selectedTabId = first.id
        host.rootView = try grid(first.id)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return firstModel.isMounted
        }

        #expect(firstModel.configuration == coordinator.gridConfiguration(for: try tab(first.id, in: fixture)))
        #expect(secondModel.configuration.primaryKeyColumns == ["code"])

        host.rootView = AnyView(Color.clear)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return !firstModel.isMounted
        }
    }
}
