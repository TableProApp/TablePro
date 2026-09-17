//
//  AccessibleControlNameTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// A control with no accessible name is silent to VoiceOver, and an icon-only button is the shape
/// that gets there by accident: it looks finished on screen because the symbol reads as a label to
/// a sighted user.
///
/// `.help()` is not a substitute, and treating it as one is what this suite exists to catch. On
/// macOS it sets the tooltip and the accessibility *hint*; VoiceOver announces the label first and
/// reads hints only after a delay, if the user has not turned them off. So a button carrying a
/// perfectly good localized string in `.help()` and nothing in `.accessibilityLabel()` announces
/// its SF Symbol name, or nothing at all.
@Suite("Accessible control names")
struct AccessibleControlNameTests {
    /// Every one of these had a name in `.help()` and none in `.accessibilityLabel()`. The pairs
    /// are (file, the label string that must appear in it), so the test fails if a label is dropped
    /// rather than merely if some label exists.
    private static let labelledControls: [(path: String, label: String)] = [
        ("TablePro/Views/Results/CellImageViewer.swift", "Open in Window"),
        ("TablePro/Views/Results/JSONViewerView.swift", "Open in Window"),
        ("TablePro/Views/Results/PhpViewerView.swift", "Open in Window"),
        ("TablePro/Views/RowInspector/FieldEditors/JsonEditorView.swift", "Open in Window"),
        ("TablePro/Views/RowInspector/FieldEditors/MultiLineEditorView.swift", "Open in Window"),
        ("TablePro/Views/Editor/QueryParameterPanelView.swift", "Close parameter panel"),
        ("TablePro/Views/Inspector/InspectorFilterBar.swift", "Remove filter"),
        ("TablePro/Views/Inspector/InspectorFilterBar.swift", "Filter column"),
        ("TablePro/Views/Inspector/InspectorFilterBar.swift", "Filter operator"),
        ("TablePro/Views/Structure/CreateTableView.swift", "Add Row"),
        ("TablePro/Views/Structure/CreateTableView.swift", "Delete Selected"),
        ("TablePro/Views/ServerDashboard/DashboardToolbarView.swift", "Refresh Now"),
        ("TablePro/Views/Settings/AIProviderDetailSheet.swift", "Copy install command"),
        ("TablePro/Views/Settings/LinkedFoldersSection.swift", "folder.name"),
        ("TablePro/Views/UsersRoles/PrivilegeChecklistView.swift", "Bulk actions"),
        ("Packages/TableProEditor/Sources/TableProEditorKit/Find/PanelView/FindControls.swift", "Previous Match"),
        ("Packages/TableProEditor/Sources/TableProEditorKit/Find/PanelView/FindControls.swift", "Next Match"),
        ("Packages/TableProEditor/Sources/TableProEditorKit/Find/PanelView/ReplaceControls.swift", "Replace All"),
        ("Packages/TableProEditor/Sources/TableProEditorKit/SupportingViews/PanelTextField.swift", "Clear")
    ]

    @Test("Every icon-only control that had only a tooltip now carries an accessibility label")
    func iconOnlyControlsCarryLabels() throws {
        let root = try repositoryRoot()
        for control in Self.labelledControls {
            let source = try String(contentsOf: root.appendingPathComponent(control.path), encoding: .utf8)
            #expect(
                source.contains(".accessibilityLabel") && source.contains(control.label),
                "\(control.path) lost the accessibility label for \(control.label)"
            )
        }
    }

    /// The find bar's clear button is the one that had neither a label nor a tooltip, so nothing
    /// named it at all.
    @Test("The panel text field's clear button is named")
    func clearButtonIsNamed() throws {
        let root = try repositoryRoot()
        let path = "Packages/TableProEditor/Sources/TableProEditorKit/SupportingViews/PanelTextField.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)

        #expect(source.contains(#".accessibilityLabel("Clear")"#))
    }

    /// Committing a foreign-key row used to happen only in `onTapGesture`, which no assistive
    /// technology can reach, so the picker's whole purpose was mouse-only.
    @Test("A foreign-key row can be committed without a mouse")
    func foreignKeyRowHasAPressAction() throws {
        let root = try repositoryRoot()
        let path = "TablePro/Views/Results/ForeignKeyPickerView.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)

        #expect(source.contains(".accessibilityAction { commit(entry) }"))
        #expect(source.contains(".accessibilityAddTraits(.isButton)"))
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw AccessibilityTestError.repositoryRootNotFound
    }

    private enum AccessibilityTestError: Error {
        case repositoryRootNotFound
    }
}

/// `NSTableView.sortDescriptors` paints the header's arrow but reaches no accessibility client,
/// measured, so a sorted column is announced only when its header cell is told directly. The plan
/// outline gives every column a `sortDescriptorPrototype`, so all of them are click-sortable, and
/// none of them said which way it was sorted.
@Suite("Query plan sort direction")
@MainActor
struct QueryPlanSortDirectionTests {
    @Test("The sorted column publishes its direction and the others publish none")
    func sortedColumnPublishesItsDirection() {
        let outlineView = NSOutlineView()
        let coordinator = QueryPlanOutlineCoordinator()
        coordinator.outlineView = outlineView
        coordinator.configureColumns(on: outlineView)

        let sortedKey = try? #require(outlineView.tableColumns.first?.identifier.rawValue)
        let key = sortedKey ?? ""
        outlineView.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
        coordinator.publishSortDirection()

        for column in outlineView.tableColumns {
            let published = column.headerCell.accessibilitySortDirection()
            if column.identifier.rawValue == key {
                #expect(published == .descending, "the sorted column published \(published.rawValue)")
            } else {
                #expect(published == .unknown, "\(column.identifier.rawValue) published \(published.rawValue)")
            }
        }
    }

    @Test("Clearing the sort clears every column's direction")
    func clearingTheSortClearsEveryDirection() {
        let outlineView = NSOutlineView()
        let coordinator = QueryPlanOutlineCoordinator()
        coordinator.outlineView = outlineView
        coordinator.configureColumns(on: outlineView)

        guard let first = outlineView.tableColumns.first else { return }
        outlineView.sortDescriptors = [NSSortDescriptor(key: first.identifier.rawValue, ascending: true)]
        coordinator.publishSortDirection()
        #expect(first.headerCell.accessibilitySortDirection() == .ascending)

        outlineView.sortDescriptors = []
        coordinator.publishSortDirection()

        for column in outlineView.tableColumns {
            #expect(column.headerCell.accessibilitySortDirection() == .unknown)
        }
    }
}
