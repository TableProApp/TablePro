import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct SplitPaneHoldingPriorityTests {
    private static let dragThatCannotResizeWindow: Float = 490

    @Test("A held pane still yields to a divider drag")
    func heldPaneYieldsToDivider() {
        #expect(NSLayoutConstraint.Priority.splitPaneHolding.rawValue < Self.dragThatCannotResizeWindow)
    }

    @Test("A held pane still outranks its sibling when the container resizes")
    func heldPaneOutranksSibling() {
        #expect(
            NSLayoutConstraint.Priority.splitPaneHolding.rawValue
                > NSLayoutConstraint.Priority.defaultLow.rawValue
        )
    }

    @Test("Privilege editor keeps room to drag at the tab's minimum width")
    func privilegeEditorKeepsDragRoom() {
        let required = UsersRolesLayoutMetrics.privilegeScopeMinimumWidth
            + UsersRolesLayoutMetrics.privilegeChecklistMinimumWidth
        #expect(UsersRolesLayoutMetrics.tabMinimumWidth - required >= 50)
    }
}

@MainActor
struct MainSplitViewControllerDetailWidthTests {
    @Test("Nil tab type falls back to the default detail minimum")
    func nilTabTypeUsesDefault() {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: nil, contentMode: .browse)
        #expect(resolved == MainSplitViewController.defaultDetailMinThickness)
    }

    @Test("Users & Roles declares the width its panes actually need")
    func usersRolesDeclaresItsOwnMinimum() {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: .usersRoles, contentMode: .browse)
        #expect(resolved == UsersRolesLayoutMetrics.tabMinimumWidth)
        #expect(resolved == 560)
    }

    @Test(
        "Every other tab type keeps the default detail minimum",
        arguments: [TabType.query, .table, .createTable, .erDiagram, .serverDashboard]
    )
    func otherTabTypesUseDefault(tabType: TabType) {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: tabType, contentMode: .browse)
        #expect(resolved == MainSplitViewController.defaultDetailMinThickness)
        #expect(resolved == 400)
    }

    /// A tab's minimum describes the tab's own content, and in Agent mode the conversation fills the
    /// detail column instead. A Users & Roles tab left selected behind it set the conversation's
    /// floor to the privilege editor's 560pt.
    @Test(
        "Agent mode keeps the default detail minimum, whatever tab is behind the conversation",
        arguments: [nil, TabType.usersRoles, .query, .table, .createTable, .erDiagram, .serverDashboard, .insights, .objectSource]
    )
    func agentModeUsesTheDefault(tabType: TabType?) {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: tabType, contentMode: .agent)
        #expect(resolved == MainSplitViewController.defaultDetailMinThickness)
    }

    @Test("Users & Roles fits its privilege editor once the principal list collapses")
    func usersRolesMinimumFitsCollapsedLayout() {
        let privilegeEditorWidth = UsersRolesLayoutMetrics.privilegeScopeMinimumWidth
            + UsersRolesLayoutMetrics.privilegeChecklistMinimumWidth
        #expect(UsersRolesLayoutMetrics.tabMinimumWidth >= privilegeEditorWidth)
    }

    @Test("Both panels hidden collapses to the base window minimum")
    func collapsedPanelsUseBaseWindowMinimum() {
        let width = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.defaultDetailMinThickness,
            sidebarVisible: false,
            inspectorVisible: false,
            sidebarMinimum: MainSplitViewController.resolveSidebarMinimumThickness(railAllowance: 0),
            dividerThickness: 1
        )
        #expect(width == MainSplitViewController.baseWindowMinWidth)
    }

    @Test("Both panels visible sums sidebar, detail, inspector and dividers")
    func visiblePanelsSumThicknesses() {
        let width = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.defaultDetailMinThickness,
            sidebarVisible: true,
            inspectorVisible: true,
            sidebarMinimum: MainSplitViewController.resolveSidebarMinimumThickness(railAllowance: 0),
            dividerThickness: 1
        )
        #expect(width == 952)
    }

    @Test("A Users & Roles tab widens the window minimum instead of pinning the inspector")
    func usersRolesWidensWindowMinimum() {
        let width = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.resolveDetailMinimumThickness(for: .usersRoles, contentMode: .browse),
            sidebarVisible: true,
            inspectorVisible: true,
            sidebarMinimum: MainSplitViewController.resolveSidebarMinimumThickness(railAllowance: 0),
            dividerThickness: 1
        )
        #expect(width == 1_112)
    }

    @Test("The workspace rail widens the window minimum by its own fixed width")
    func railWidensWindowMinimum() {
        let withoutRail = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.defaultDetailMinThickness,
            sidebarVisible: true,
            inspectorVisible: true,
            sidebarMinimum: MainSplitViewController.resolveSidebarMinimumThickness(railAllowance: 0),
            dividerThickness: 1
        )
        let withRail = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.defaultDetailMinThickness,
            sidebarVisible: true,
            inspectorVisible: true,
            sidebarMinimum: MainSplitViewController.resolveSidebarMinimumThickness(
                railAllowance: WorkspaceRailMetrics.medium.width + 1
            ),
            dividerThickness: 1
        )
        #expect(withRail == withoutRail + WorkspaceRailMetrics.medium.width + 1)
    }

    @Test("A collapsed sidebar takes the rail with it, so it reserves no width")
    func railReservesNothingWhenSidebarCollapsed() {
        let collapsed = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.defaultDetailMinThickness,
            sidebarVisible: false,
            inspectorVisible: false,
            sidebarMinimum: MainSplitViewController.resolveSidebarMinimumThickness(
                railAllowance: WorkspaceRailMetrics.medium.width + 1
            ),
            dividerThickness: 1
        )
        #expect(collapsed == MainSplitViewController.baseWindowMinWidth)
    }
}
