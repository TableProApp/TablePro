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

    /// A pop up button carries the selected value, the checkmark and the menu role for free.
    /// Hand-drawn checkmarks reported nothing to VoiceOver, and the indentation was a run of
    /// spaces glued onto the name, which reads out loud and collapses in right-to-left.
    var body: some View {
        HStack(spacing: 6) {
            Picker(String(localized: "Group"), selection: $selectedGroupId) {
                Text("None").tag(UUID?.none)
                Divider()
                hierarchicalGroupItems()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Group"))

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Group...", systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Create New Group..."))
            .accessibilityLabel(Text("Create New Group..."))
        }
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
            Label {
                Text(entry.group.name)
            } icon: {
                if !entry.group.color.isDefault {
                    Image(nsImage: colorDot(entry.group.color.color))
                }
            }
            .padding(.leading, CGFloat(entry.depth) * Self.depthIndent)
            .tag(UUID?.some(entry.group.id))
        }
    }

    private static let depthIndent: CGFloat = 12

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
                ColorPaletteView(selectedColor: $groupColor, includesNone: true, size: .compact)
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
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onSave(groupName, groupColor, selectedParentId)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
