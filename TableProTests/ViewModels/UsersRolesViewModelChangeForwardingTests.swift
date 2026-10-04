//
//  UsersRolesViewModelChangeForwardingTests.swift
//  TableProTests
//
//  The Users & Roles views observe the view model and read staged changes through it, so a change
//  the change manager publishes has to reach them as a change of the view model.
//

import Combine
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct UsersRolesViewModelChangeForwardingTests {
    private final class Counter {
        var value = 0
    }

    private let alice = PluginPrincipalRef(name: "alice")
    private let app = PluginPrivilegeScope.database("app")

    private func makeViewModel() -> UsersRolesViewModel {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        viewModel.changeManager.load(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog(
                databasePrivileges: [
                    PluginPrivilegeDescriptor(name: "CONNECT", label: "Connect"),
                    PluginPrivilegeDescriptor(name: "CREATE", label: "Create")
                ]
            )
        )
        viewModel.changeManager.loadGrants(
            [PluginGrantInfo(privilege: "CONNECT", scope: app, isGrantable: false)],
            for: alice
        )
        viewModel.selection = alice
        viewModel.selectedRefs = [alice]
        viewModel.selectedScopes = [app]
        return viewModel
    }

    @Test("Ticking a privilege is a change of the view model the checklist observes")
    func tickingAPrivilegeNotifiesTheViewModel() {
        let viewModel = makeViewModel()
        let notifications = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        defer { subscription.cancel() }

        viewModel.setGranted(true, privilege: "CREATE")

        #expect(notifications.value > 0, "the tick was staged but nothing observing the view model heard it")
        #expect(viewModel.grantState(for: "CREATE") == .checked)
        #expect(viewModel.hasChanges)
    }

    @Test("Undoing a staged grant notifies the view model too")
    func undoNotifiesTheViewModel() {
        let viewModel = makeViewModel()
        viewModel.setGranted(true, privilege: "CREATE")
        let notifications = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        defer { subscription.cancel() }

        viewModel.undo()

        #expect(notifications.value > 0)
        #expect(viewModel.grantState(for: "CREATE") == .unchecked)
        #expect(!viewModel.hasChanges)
    }
}
