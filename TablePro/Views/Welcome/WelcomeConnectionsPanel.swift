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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .contextMenu { WelcomeNewConnectionMenu(vm: vm) }
        .onReceive(NotificationCenter.default.publisher(for: .welcomeWindowFindRequested)) { _ in
            searchFocusTrigger += 1
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.listState {
        case .content:
            WelcomeConnectionList(vm: vm, focus: focus)
        case .firstRun:
            firstRunState
        case .noSearchMatch(let term):
            ContentUnavailableView.search(text: term)
        case .noFilterMatch:
            EmptyStateView(
                icon: "tag",
                title: String(localized: "No Matching Connections"),
                description: String(localized: "No connections have the selected tags."),
                actionTitle: String(localized: "Clear Filter"),
                action: { vm.tagFilter.selectedIds.removeAll() }
            )
        }
    }

    private var firstRunState: some View {
        EmptyStateView(
            icon: "cylinder.split.1x2",
            title: String(localized: "No Connections"),
            description: String(localized: "Connect to your own database, or open the sample database to look around."),
            actionTitle: String(localized: "Open Sample Database"),
            action: { vm.openSampleDatabase() },
            secondaryActionTitle: vm.hasImportableApp ? String(localized: "Import from Other App…") : nil,
            secondaryAction: vm.hasImportableApp ? { vm.importConnectionsFromApp() } : nil
        )
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
                placeholder: String(localized: "Search Connections"),
                controlSize: .regular,
                onMoveDown: { focus.wrappedValue = .connectionList },
                onSubmit: { focus.wrappedValue = .connectionList },
                focusTrigger: searchFocusTrigger,
                maxWidth: 240
            )
            .focused(focus, equals: .search)
            .disabled(!vm.isSearchAvailable)
            .layoutPriority(0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
