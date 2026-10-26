import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct PrivilegeScopeOutlineSelectionTests {
    // Never ordered front and never closed: `close()` on a test window over-releases it.
    private func mount(selecting scopes: Set<PluginPrivilegeScope>) throws -> (PrivilegeScopeOutline, PrivilegeScopeOutlineCoordinator) {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        viewModel.privilegeTree.showGrantedOnly(scopes: [.database("app"), .database("web")])
        viewModel.selectedScopes = scopes
        let coordinator = PrivilegeScopeOutlineCoordinator(viewModel: viewModel)
        let scrollView = PrivilegeScopeOutlineView.makeScrollView(coordinator: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let outline = try #require(scrollView.documentView as? PrivilegeScopeOutline)
        outline.reloadData()
        return (outline, coordinator)
    }

    private func row(of scope: PluginPrivilegeScope, in outline: NSOutlineView) -> Int? {
        (0 ..< outline.numberOfRows).first { (outline.item(atRow: $0) as? PrivilegeNode)?.scope == scope }
    }

    @Test("A rebuilt outline selects the rows of the scopes the checklist still edits")
    func rebuiltOutlineSelectsTheModelScopes() throws {
        let (outline, coordinator) = try mount(selecting: [.database("web")])
        #expect(outline.selectedRowIndexes.isEmpty)

        coordinator.restoreExpansion()

        let web = try #require(row(of: .database("web"), in: outline))
        #expect(outline.selectedRowIndexes == IndexSet(integer: web))
        #expect(coordinator.viewModel.selectedScopes == [.database("web")])
    }

    @Test("A selected scope with no row stays selected in the model")
    func scopeWithoutARowIsKept() throws {
        let (outline, coordinator) = try mount(selecting: [.database("web"), .database("archive")])

        coordinator.restoreExpansion()

        #expect(outline.selectedRowIndexes.count == 1)
        #expect(coordinator.viewModel.selectedScopes == [.database("web"), .database("archive")])
    }
}
