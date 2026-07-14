import Foundation
@testable import TablePro
import Testing

@Suite("MainSplitViewController detail width")
@MainActor
struct MainSplitViewControllerDetailWidthTests {
    @Test("Nil tab type falls back to the default detail minimum")
    func nilTabTypeUsesDefault() {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: nil)
        #expect(resolved == MainSplitViewController.defaultDetailMinThickness)
    }

    @Test("Users & Roles declares the width its panes actually need")
    func usersRolesDeclaresItsOwnMinimum() {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: .usersRoles)
        #expect(resolved == UsersRolesLayoutMetrics.tabMinimumWidth)
        #expect(resolved == 560)
    }

    @Test(
        "Every other tab type keeps the default detail minimum",
        arguments: [TabType.query, .table, .createTable, .erDiagram, .serverDashboard]
    )
    func otherTabTypesUseDefault(tabType: TabType) {
        let resolved = MainSplitViewController.resolveDetailMinimumThickness(for: tabType)
        #expect(resolved == MainSplitViewController.defaultDetailMinThickness)
        #expect(resolved == 400)
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
            dividerThickness: 1
        )
        #expect(width == 952)
    }

    @Test("A Users & Roles tab widens the window minimum instead of pinning the inspector")
    func usersRolesWidensWindowMinimum() {
        let width = MainSplitViewController.resolveWindowMinWidth(
            detailMinimum: MainSplitViewController.resolveDetailMinimumThickness(for: .usersRoles),
            sidebarVisible: true,
            inspectorVisible: true,
            dividerThickness: 1
        )
        #expect(width == 1_112)
    }
}
