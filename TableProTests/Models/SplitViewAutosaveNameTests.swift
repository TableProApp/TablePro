//
//  SplitViewAutosaveNameTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Split view autosave name")
struct SplitViewAutosaveNameTests {
    /// A real user's saved widths and collapse states hang off this exact string. Versioning it
    /// discards all of them, so production must keep the bare name whatever the sandbox does.
    @Test("Production keeps the bare name")
    func productionIsUnnamespaced() {
        #expect(SplitViewAutosaveName.resolved(isIsolated: false, sandboxIdentifier: "ABC") == "com.TablePro.mainSplit")
        #expect(SplitViewAutosaveName.resolved(isIsolated: false, sandboxIdentifier: nil) == "com.TablePro.mainSplit")
    }

    /// AppKit files the autosave record in the standard defaults domain, which the UI test sandbox
    /// does not redirect, so without this every case inherits the pane geometry of whichever case
    /// ran before it in its shard.
    @Test("A sandboxed run gets its own record")
    func isolationNamespacesTheRecord() {
        let name = SplitViewAutosaveName.resolved(isIsolated: true, sandboxIdentifier: "ABC-123")

        #expect(name == "com.TablePro.mainSplit.ABC-123")
        #expect(name != SplitViewAutosaveName.base)
    }

    /// The whole point is that two cases cannot collide. The sandbox root's last path component is
    /// a fresh UUID per case, which is what supplies the difference.
    @Test("Two sandboxes never share a record")
    func twoSandboxesDoNotCollide() {
        let first = SplitViewAutosaveName.resolved(isIsolated: true, sandboxIdentifier: "case-one")
        let second = SplitViewAutosaveName.resolved(isIsolated: true, sandboxIdentifier: "case-two")

        #expect(first != second)
    }

    /// An empty identifier would namespace to a trailing dot shared by every case, which is the
    /// collision this exists to prevent wearing a different name.
    @Test("An empty identifier falls back rather than sharing a suffix")
    func emptyIdentifierFallsBack() {
        #expect(SplitViewAutosaveName.resolved(isIsolated: true, sandboxIdentifier: "") == SplitViewAutosaveName.base)
        #expect(SplitViewAutosaveName.resolved(isIsolated: true, sandboxIdentifier: nil) == SplitViewAutosaveName.base)
    }

    /// Every autosave name in the app goes through the same helper, because they all land in the
    /// same unisolated defaults: the window frames, the tab-content split dividers and the query
    /// history drawer's own list/detail divider, which is the one that pushed a drawer's action bar
    /// past the window's bottom edge.
    @Test("The general form namespaces any name")
    func anyNameIsNamespaced() {
        let drawer = "com.TablePro.queryHistory.listDetail"
        #expect(
            SplitViewAutosaveName.resolved(drawer, isIsolated: true, sandboxIdentifier: "s1")
                == "com.TablePro.queryHistory.listDetail.s1"
        )
        #expect(
            SplitViewAutosaveName.resolved(drawer, isIsolated: false, sandboxIdentifier: "s1") == drawer
        )
        #expect(
            SplitViewAutosaveName.resolved("TextViewerWindow", isIsolated: true, sandboxIdentifier: "s1")
                != SplitViewAutosaveName.resolved("JSONViewerWindow", isIsolated: true, sandboxIdentifier: "s1")
        )
    }

    /// The rule is only useful if the call sites actually use it. A new autosave name assigned
    /// directly is a new leak, and this is what catches one.
    @Test("Every autosave assignment goes through the helper")
    func everyCallSiteIsNamespaced() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sites = [
            "TablePro/Views/Components/AutosavingSplitView.swift",
            "TablePro/Views/Components/VerticalCollapsibleSplitView.swift",
            "TablePro/Views/ServerDashboard/ServerDashboardSplitView.swift",
            "TablePro/Views/QueryPlan/QueryPlanOutlineView.swift",
            "TablePro/Views/UsersRoles/PrivilegeScopeOutlineView.swift",
            "TablePro/Views/ConnectionForm/ConnectionFormWindowController.swift",
            "TablePro/Views/Integrations/IntegrationsActivityWindowController.swift",
            "TablePro/Core/Services/Infrastructure/TabWindowController.swift",
            "TablePro/Extensions/NSWindow+FrameAutosave.swift",
            "TablePro/Core/Services/Infrastructure/MainSplitViewController.swift",
        ]

        var offenders: [String] = []
        for site in sites {
            let source = try String(contentsOf: root.appendingPathComponent(site), encoding: .utf8)
            if !source.contains("SplitViewAutosaveName") {
                offenders.append(site)
            }
        }

        #expect(offenders.isEmpty, "These assign an autosave name without namespacing it: \(offenders)")
    }
}
