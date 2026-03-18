//
//  ConnectionGroupPicker.swift
//  TablePro
//

import SwiftUI

/// Group selection dropdown for the connection form
struct ConnectionGroupPicker: View {
    @Binding var selectedGroupId: UUID?
    @State private var allGroups: [ConnectionGroup] = []
    @State private var showingCreateSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var groupToDelete: ConnectionGroup?

    private let groupStorage = GroupStorage.shared

    private var selectedGroup: ConnectionGroup? {
        guard let id = selectedGroupId else { return nil }
        return groupStorage.group(for: id)
    }

    private func children(of parentId: UUID?) -> [ConnectionGroup] {
        allGroups
            .filter { $0.parentGroupId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Menu {
            Button {
                selectedGroupId = nil
            } label: {
                HStack {
                    Text("None")
                    if selectedGroupId == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            let rootGroups = children(of: nil)
            if !rootGroups.isEmpty {
                Divider()
            }

            ForEach(rootGroups) { group in
                groupMenuItem(group)
            }

            Divider()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Group...", systemImage: "plus.circle")
            }

            if !allGroups.isEmpty {
                Divider()

                Menu("Manage Groups") {
                    ForEach(allGroups) { group in
                        Button(role: .destructive) {
                            groupToDelete = group
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete \"\(group.name)\"", systemImage: "trash")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let group = selectedGroup {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(group.color.color)
                        .font(.system(size: 10))
                    Text(group.name)
                        .foregroundStyle(.primary)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task { allGroups = groupStorage.loadGroups() }
        .sheet(isPresented: $showingCreateSheet) {
            ConnectionGroupFormSheet { newGroup in
                if groupStorage.addGroup(newGroup) {
                    selectedGroupId = newGroup.id
                }
                allGroups = groupStorage.loadGroups()
            }
        }
        .confirmationDialog(
            String(localized: "Delete Group"),
            isPresented: $showingDeleteConfirmation,
            presenting: groupToDelete
        ) { group in
            Button(String(localized: "Delete"), role: .destructive) {
                deleteGroup(group)
            }
        } message: { group in
            let count = groupStorage.connectionCount(for: group)
            if count > 0 {
                Text("Delete \"\(group.name)\" and its \(count) connection(s)?")
            } else {
                Text("Delete \"\(group.name)\"?")
            }
        }
    }

    // MARK: - Helpers

    private func groupMenuItem(_ group: ConnectionGroup) -> AnyView {
        let subgroups = children(of: group.id)
        if subgroups.isEmpty {
            return AnyView(
                Button {
                    selectedGroupId = group.id
                } label: {
                    HStack {
                        Image(nsImage: colorDot(group.color.color))
                        Text(group.name)
                        if selectedGroupId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            )
        } else {
            return AnyView(
                Menu {
                    Button {
                        selectedGroupId = group.id
                    } label: {
                        HStack {
                            Image(nsImage: colorDot(group.color.color))
                            Text(group.name)
                            if selectedGroupId == group.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(subgroups) { child in
                        groupMenuItem(child)
                    }
                } label: {
                    HStack {
                        Image(nsImage: colorDot(group.color.color))
                        Text(group.name)
                        if selectedGroupId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            )
        }
    }

    private func colorDot(_ color: Color) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func deleteGroup(_ group: ConnectionGroup) {
        if selectedGroupId == group.id {
            selectedGroupId = nil
        }
        groupStorage.deleteGroup(group)
        allGroups = groupStorage.loadGroups()
    }
}

// MARK: - Group Color Picker

private struct GroupColorPicker: View {
    @Binding var selectedColor: ConnectionColor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ConnectionColor.allCases) { color in
                Button(action: { selectedColor = color }) {
                    Circle()
                        .fill(color == .none ? Color(nsColor: .quaternaryLabelColor) : color.color)
                        .frame(width: ThemeEngine.shared.activeTheme.iconSizes.medium, height: ThemeEngine.shared.activeTheme.iconSizes.medium)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                                .frame(
                                    width: ThemeEngine.shared.activeTheme.iconSizes.large,
                                    height: ThemeEngine.shared.activeTheme.iconSizes.large
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Color \(color.rawValue)"))
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var groupId: UUID?

        var body: some View {
            VStack(spacing: 20) {
                ConnectionGroupPicker(selectedGroupId: $groupId)
                Text("Selected: \(groupId?.uuidString ?? "none")")
            }
            .padding()
            .frame(width: 400)
        }
    }

    return PreviewWrapper()
}
