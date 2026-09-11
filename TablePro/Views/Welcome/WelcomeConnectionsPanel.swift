//
//  WelcomeConnectionsPanel.swift
//  TablePro
//

import SwiftUI

internal struct WelcomeConnectionsPanel: View {
    @Bindable var vm: WelcomeViewModel
    var focus: FocusState<WelcomeFocusField?>.Binding
    @State private var searchFocusTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !vm.availableTags.isEmpty {
                TagFilterBar(tagFilter: $vm.tagFilter, availableTags: vm.availableTags)
                Divider()
            }
            ZStack {
                if vm.treeItems.isEmpty && vm.linkedConnections.isEmpty && vm.teamLibraryConnections.isEmpty
                    && vm.favoriteConnections.isEmpty {
                    emptyState
                } else {
                    WelcomeConnectionList(vm: vm, focus: focus)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .contextMenu { WelcomeNewConnectionMenu(vm: vm) }
        .onReceive(NotificationCenter.default.publisher(for: .welcomeWindowFindRequested)) { _ in
            searchFocusTrigger += 1
        }
    }

    private var newConnectionHelp: String {
        let binding = AppSettingsManager.shared.keyboard.shortcut(for: .newConnection)
        guard let displayString = binding?.displayString, !displayString.isEmpty else {
            return String(localized: "New Connection")
        }
        return String(format: String(localized: "New Connection (%@)"), displayString)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                WindowOpener.shared.openConnectionForm()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(newConnectionHelp)
            .accessibilityLabel(String(localized: "New Connection"))

            Button {
                vm.pendingMoveToNewGroup = []
                vm.activeSheet = .newGroup(parentId: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(String(localized: "New Group"))
            .accessibilityLabel(String(localized: "New Group"))

            Spacer()

            NativeSearchField(
                text: $vm.searchText,
                placeholder: String(localized: "Search for connection…"),
                controlSize: .regular,
                onMoveDown: { focus.wrappedValue = .connectionList },
                onSubmit: { focus.wrappedValue = .connectionList },
                focusTrigger: searchFocusTrigger,
                maxWidth: 240
            )
            .focused(focus, equals: .search)
            .layoutPriority(0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var emptyState: some View {
        if vm.searchText.isEmpty {
            EmptyStateView(
                icon: "cylinder.split.1x2",
                title: String(localized: "No Connections"),
                description: String(localized: "Try the sample database, or click + above to add your own."),
                actionTitle: String(localized: "Try Sample Database"),
                action: { vm.openSampleDatabase() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "magnifyingglass",
                title: String(localized: "No Matching Connections"),
                description: String(localized: "Try a different search term.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
