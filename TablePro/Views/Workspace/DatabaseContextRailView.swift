import AppKit
import SwiftUI

// DatabaseContextRailView.swift — vertical rail list and actions
// Part of the Database Context Rail feature (Task 5 of the plan).

@MainActor
struct DatabaseContextRailView: View {
    @Bindable private var registry: WorkspaceContextRegistry
    private let activationCoordinator: WorkspaceContextActivationCoordinator
    private let closeCoordinator: WorkspaceContextCloseCoordinator

    init(
        registry: WorkspaceContextRegistry,
        activationCoordinator: WorkspaceContextActivationCoordinator,
        closeCoordinator: WorkspaceContextCloseCoordinator
    ) {
        self.registry = registry
        self.activationCoordinator = activationCoordinator
        self.closeCoordinator = closeCoordinator
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(registry.contexts) { descriptor in
                    DatabaseContextRailItemView(
                        descriptor: descriptor,
                        isSelected: registry.selectedKey == descriptor.key,
                        onSelect: {
                            activationCoordinator.activate(
                                descriptor.key,
                                preferredWindowId: nil,
                                sourceWindow: NSApp.keyWindow
                            )
                        },
                        onClose: {
                            Task {
                                _ = await closeCoordinator.close(
                                    key: descriptor.key,
                                    sourceWindow: NSApp.keyWindow
                                )
                            }
                        }
                    )
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-rail")
        .accessibilityLabel(String(localized: "Open Workspaces"))
    }
}
