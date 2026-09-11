//
//  WelcomeGroupRows.swift
//  TablePro
//

import SwiftUI

internal struct WelcomeTreeRows<ConnectionContent: View>: View {
    let items: [ConnectionGroupTreeNode]
    let parentGroupId: UUID?
    var vm: WelcomeViewModel
    let connectionRowBuilder: (DatabaseConnection) -> ConnectionContent

    private var hasGroups: Bool {
        items.contains { node in
            if case .group = node { return true }
            return false
        }
    }

    var body: some View {
        let allConnections = !hasGroups
        ForEach(items) { item in
            switch item {
            case .connection(let conn):
                connectionRowBuilder(conn)
            case .group(let group, let children):
                DisclosureGroup(isExpanded: expandedBinding(for: group.id)) {
                    WelcomeTreeRows(
                        items: children,
                        parentGroupId: group.id,
                        vm: vm,
                        connectionRowBuilder: connectionRowBuilder
                    )
                } label: {
                    WelcomeGroupLabel(group: group, vm: vm)
                }
                .listRowSeparator(.hidden)
            }
        }
        .onMove(perform: allConnections ? { from, to in
            guard vm.searchText.isEmpty else { return }
            vm.moveConnections(
                renderedIds: items.compactMap { item in
                    guard case .connection(let conn) = item else { return nil }
                    return conn.id
                },
                from: from,
                to: to,
                inGroup: parentGroupId
            )
        } : nil)
    }

    private func expandedBinding(for groupId: UUID) -> Binding<Bool> {
        Binding(
            get: { vm.expandedGroupIds.contains(groupId) },
            set: { expanded in
                if expanded {
                    vm.expandedGroupIds.insert(groupId)
                } else {
                    vm.expandedGroupIds.remove(groupId)
                }
            }
        )
    }
}

private struct WelcomeGroupLabel: View {
    let group: ConnectionGroup
    var vm: WelcomeViewModel

    var body: some View {
        HStack(spacing: 6) {
            if !group.color.isDefault {
                Circle()
                    .fill(group.color.color)
                    .frame(width: 8, height: 8)
            }

            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(vm.connectionCountByGroup[group.id] ?? 0)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            groupContextMenu
        }
    }

    @ViewBuilder
    private var groupContextMenu: some View {
        Button {
            vm.beginRenameGroup(group)
        } label: {
            Label(String(localized: "Rename"), systemImage: "pencil")
        }

        let currentGroupDepth = vm.depthByGroup[group.id] ?? 0
        Button {
            vm.createSubgroup(under: group.id)
        } label: {
            Label(String(localized: "New Subgroup"), systemImage: "folder.badge.plus")
        }
        .disabled(currentGroupDepth >= 3)

        Menu(String(localized: "Change Color")) {
            ForEach(ConnectionColor.allCases) { color in
                Button {
                    vm.updateGroupColor(group, color: color)
                } label: {
                    HStack {
                        if color != .none {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(color.color)
                        }
                        Text(color.displayName)
                        if group.color == color {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        if vm.groups.count > 1 {
            Menu(String(localized: "Move Group to…")) {
                Button {
                    vm.moveGroup(group, toParent: nil)
                } label: {
                    HStack {
                        Text("Top Level")
                        if group.parentId == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(group.parentId == nil)

                Divider()

                ForEach(vm.groups.filter({ $0.id != group.id })) { targetGroup in
                    let canPlace = canPlaceGroup(group.id, under: targetGroup.id, groups: vm.groups)

                    Button {
                        vm.moveGroup(group, toParent: targetGroup.id)
                    } label: {
                        HStack {
                            if !targetGroup.color.isDefault {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(targetGroup.color.color)
                            }
                            Text(targetGroup.name)
                            if group.parentId == targetGroup.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!canPlace || group.parentId == targetGroup.id)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            vm.requestDeleteGroup(group)
        } label: {
            Label(String(localized: "Delete Group"), systemImage: "trash")
        }
    }
}
