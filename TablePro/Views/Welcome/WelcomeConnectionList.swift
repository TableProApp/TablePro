//
//  WelcomeConnectionList.swift
//  TablePro
//

import SwiftUI

internal struct WelcomeConnectionList: View {
    @Bindable var vm: WelcomeViewModel
    var focus: FocusState<WelcomeFocusField?>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $vm.selectedConnectionIds) {
                let treeHasGroups = vm.treeItems.contains { item in
                    if case .group = item { return true }
                    return false
                }
                let treeNeedsHeader = vm.showsFavoritesSection && !treeHasGroups && !vm.treeItems.isEmpty

                if vm.showsFavoritesSection {
                    Section {
                        ForEach(vm.favoriteConnections) { conn in
                            connectionRow(for: conn)
                        }
                    } header: {
                        sectionHeader(String(localized: "Favorites"))
                    }
                }

                if treeNeedsHeader {
                    Section {
                        WelcomeTreeRows(items: vm.treeItems, parentGroupId: nil, vm: vm) { conn in
                            connectionRow(for: conn)
                        }
                    } header: {
                        sectionHeader(String(localized: "Connections"))
                    }
                } else {
                    WelcomeTreeRows(items: vm.treeItems, parentGroupId: nil, vm: vm) { conn in
                        connectionRow(for: conn)
                    }
                }

                if !vm.visibleLinkedConnections.isEmpty {
                    Section {
                        ForEach(vm.visibleLinkedConnections) { linked in
                            WelcomeExternalConnectionRow(linked: linked, badgeSystemImage: "folder.fill")
                        }
                    } header: {
                        sectionHeader(String(localized: "Linked"))
                    }
                }

                if !vm.visibleTeamLibraryConnections.isEmpty {
                    Section {
                        ForEach(vm.visibleTeamLibraryConnections) { linked in
                            WelcomeExternalConnectionRow(linked: linked, badgeSystemImage: "person.2.fill")
                        }
                    } header: {
                        sectionHeader(String(localized: "Team Library"))
                    }
                }
            }
            .listStyle(.inset)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .focused(focus, equals: .connectionList)
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenuContent(for: ids)
            } primaryAction: { ids in
                primaryAction(for: ids)
            }
            .onKeyPress(characters: .init(charactersIn: "\u{7F}\u{08}"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                let toDelete = vm.selectedConnections
                guard !toDelete.isEmpty else { return .ignored }
                vm.requestDeleteConnections(toDelete)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "a"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                vm.selectedConnectionIds = Set(vm.flatVisibleConnections.map(\.id))
                return .handled
            }
            .onKeyPress(.escape) {
                if !vm.selectedConnectionIds.isEmpty {
                    vm.selectedConnectionIds = []
                }
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.moveToNextConnection()
                scrollToSelection(proxy)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.moveToPreviousConnection()
                scrollToSelection(proxy)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "h"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.collapseSelectedGroup()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "l"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.expandSelectedGroup()
                return .handled
            }
        }
    }

    func connectionRow(for connection: DatabaseConnection) -> some View {
        let metadata = vm.rowMetadata(for: connection)
        return WelcomeConnectionRow(
            connection: connection,
            tags: metadata.tags,
            group: metadata.group,
            isSelected: vm.selectedConnectionIds.contains(connection.id),
            onToggleFavorite: { vm.toggleFavorite([connection]) }
        )
        .tag(connection.id)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            editConnectionButton(for: connection)
            deleteConnectionButton(for: connection)
        }
    }

    func primaryAction(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for connection in vm.connections where ids.contains(connection.id) {
            vm.connectToDatabase(connection)
        }
        for linked in vm.linkedConnections where ids.contains(linked.id) {
            vm.connectToLinkedConnection(linked)
        }
        for linked in vm.teamLibraryConnections where ids.contains(linked.id) {
            vm.connectToLinkedConnection(linked)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let id = vm.selectedConnectionIds.first {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
