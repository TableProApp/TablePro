//
//  ConnectionGroupPicker.swift
//  TablePro
//
//  Group selector dropdown for connection form
//

import SwiftUI

/// Group selection for a connection — single Menu dropdown
struct ConnectionGroupPicker: View {
    @Binding var selectedGroupId: UUID?
    @State private var allGroups: [ConnectionGroup] = []
    @State private var showingCreateSheet = false

    private let groupStorage = GroupStorage.shared

    private var selectedGroup: ConnectionGroup? {
        guard let id = selectedGroupId else { return nil }
        return allGroups.first { $0.id == id }
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

            Divider()

            hierarchicalGroupItems()

            Divider()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Group...", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 6) {
                if let group = selectedGroup {
                    if !group.color.isDefault {
                        Circle()
                            .fill(group.color.color)
                            .frame(width: 8, height: 8)
                    }
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
            CreateGroupSheet { groupName, groupColor, parentId in
                let group = ConnectionGroup(name: groupName, color: groupColor, parentId: parentId)
                groupStorage.addGroup(group)
                selectedGroupId = group.id
                allGroups = groupStorage.loadGroups()
            }
        }
    }

    @ViewBuilder
    private func hierarchicalGroupItems() -> some View {
        let flatGroups = flattenGroupsForMenu(groups: allGroups)
        ForEach(flatGroups, id: \.group.id) { entry in
            Button {
                selectedGroupId = entry.group.id
            } label: {
                HStack {
                    if !entry.group.color.isDefault {
                        Image(nsImage: colorDot(entry.group.color.color))
                    }
                    Text(String(repeating: "  ", count: entry.depth) + entry.group.name)
                    if selectedGroupId == entry.group.id {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
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
}

// MARK: - Create Group Sheet

struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groupName: String = ""
    @State private var groupColor: ConnectionColor = .none
    @State private var selectedParentId: UUID?
    @State private var allGroups: [ConnectionGroup] = []

    private let initialParentId: UUID?
    let onSave: (String, ConnectionColor, UUID?) -> Void

    init(parentId: UUID? = nil, onSave: @escaping (String, ConnectionColor, UUID?) -> Void) {
        self.initialParentId = parentId
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Group")
                .font(.headline)

            TextField("Group name", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GroupColorPicker(selectedColor: $groupColor)
            }

            if !allGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Parent Group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ParentGroupPicker(selectedParentId: $selectedParentId, allGroups: allGroups)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Button("Create") {
                    onSave(groupName, groupColor, selectedParentId)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            allGroups = GroupStorage.shared.loadGroups()
            selectedParentId = initialParentId
        }
        .onExitCommand {
            dismiss()
        }
    }
}

// MARK: - Parent Group Picker

private struct ParentGroupPicker: View {
    @Binding var selectedParentId: UUID?
    let allGroups: [ConnectionGroup]

    var body: some View {
        Menu {
            Button {
                selectedParentId = nil
            } label: {
                HStack {
                    Text("None (Top Level)")
                    if selectedParentId == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(allGroups.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { group in
                let depth = depthOf(groupId: group.id, groups: allGroups)
                Button {
                    selectedParentId = group.id
                } label: {
                    HStack {
                        Text(String(repeating: "  ", count: max(0, depth - 1)) + group.name)
                        if selectedParentId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(depth >= 3)
            }
        } label: {
            Text(parentLabel)
                .foregroundStyle(selectedParentId == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var parentLabel: String {
        guard let pid = selectedParentId,
              let group = allGroups.first(where: { $0.id == pid }) else {
            return String(localized: "None (Top Level)")
        }
        return group.name
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
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                                .frame(
                                    width: 20,
                                    height: 20
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: String(localized: "Color %@"), color.rawValue))
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
