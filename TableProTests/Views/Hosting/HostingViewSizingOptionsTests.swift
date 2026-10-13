//
//  HostingViewSizingOptionsTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

/// `NSHostingView.sizingOptions` defaults to `.standardBounds`, which measures a minimum, an
/// intrinsic and a maximum size on every layout pass and publishes all three to the enclosing
/// AppKit view. CLAUDE.md's rule about that cost, and about a nested minimum reaching the window's
/// split dividers, is written entirely in terms of `NSHostingController`; `NSHostingView` inherits
/// none of it. A host pinned to a container it does not size states `[]`.
struct HostingViewSizingOptionsTests {
    /// Each host is pinned by constraints or by the enclosing table's own row geometry, so none of
    /// them may publish a size of its own. A window's `contentView` is deliberately not on this
    /// list: there `.standardBounds` is what sets the window's min and max content size.
    private static let pinnedHosts = [
        "TablePro/Views/Sidebar/SourceList/SidebarHostingCellView.swift",
        "TablePro/Views/Shared/FieldDrivenList.swift",
        "TablePro/Views/DataFiles/DataFileSplitViewController.swift",
        "TablePro/Views/Components/CheckboxOutlineView.swift",
        "TablePro/Views/QueryPlan/QueryPlanDiagramCanvasView.swift",
    ]

    @Test("Every hosting view pinned to its container states its sizing options")
    func pinnedHostsDeclareSizingOptions() throws {
        let root = try repositoryRoot()

        for source in Self.pinnedHosts {
            let text = try String(contentsOf: root.appendingPathComponent(source), encoding: .utf8)
            #expect(
                text.contains("sizingOptions = []"),
                """
                \(source) builds an `NSHostingView` that its container already sizes, so it must \
                set `sizingOptions = []`. Left at `.standardBounds` it measures three sizes per \
                layout pass and can pin the enclosing split view's dividers.
                """
            )
        }
    }

    private static let chromeHostedOutlines = [
        "TablePro/Views/QueryPlan/QueryPlanOutlineCoordinator.swift",
        "TablePro/Views/UsersRoles/PrivilegeScopeOutlineView.swift",
    ]

    @Test("The records outlines host every cell through the theme chrome's cell, which states its sizing options")
    @MainActor
    func chromeHostedCellsDeclareSizingOptions() throws {
        let cell = ThemeTableChrome.HostingCell.make(
            NSUserInterfaceItemIdentifier("cell"),
            in: NSTableView(),
            showing: Text(verbatim: "value")
        )
        #expect(cell.sizingOptions.isEmpty)

        let root = try repositoryRoot()
        for source in Self.chromeHostedOutlines {
            let text = try String(contentsOf: root.appendingPathComponent(source), encoding: .utf8)
            #expect(text.contains("ThemeTableChrome.HostingCell.make("), "\(source) no longer hosts its cells through ThemeTableChrome.HostingCell")
            #expect(!text.contains("NSHostingView("), "\(source) builds an NSHostingView of its own; set `sizingOptions = []` on it")
        }
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SizingTestError.repositoryRootNotFound
    }

    private enum SizingTestError: Error {
        case repositoryRootNotFound
    }
}
