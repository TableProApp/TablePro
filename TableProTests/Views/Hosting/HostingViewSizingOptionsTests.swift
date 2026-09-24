//
//  HostingViewSizingOptionsTests.swift
//  TableProTests
//

import Foundation
import Testing

/// `NSHostingView.sizingOptions` defaults to `.standardBounds`, which measures a minimum, an
/// intrinsic and a maximum size on every layout pass and publishes all three to the enclosing
/// AppKit view. CLAUDE.md's rule about that cost, and about a nested minimum reaching the window's
/// split dividers, is written entirely in terms of `NSHostingController`; `NSHostingView` inherits
/// none of it. A host pinned to a container it does not size states `[]`.
@Suite("Hosting view sizing options")
struct HostingViewSizingOptionsTests {
    /// Each host is pinned by constraints or by the enclosing table's own row geometry, so none of
    /// them may publish a size of its own. A window's `contentView` is deliberately not on this
    /// list: there `.standardBounds` is what sets the window's min and max content size.
    private static let pinnedHosts = [
        "TablePro/Views/Sidebar/SourceList/SidebarHostingCellView.swift",
        "TablePro/Views/Shared/FieldDrivenList.swift",
        "TablePro/Views/DataFiles/DataFileSplitViewController.swift",
        "TablePro/Views/QueryPlan/QueryPlanOutlineCoordinator.swift",
        "TablePro/Views/UsersRoles/PrivilegeScopeOutlineCoordinator.swift",
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
