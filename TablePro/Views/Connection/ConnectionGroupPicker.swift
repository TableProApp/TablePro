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
            // None option
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

            // Available groups
            ForEach(allGroups) { group in
                Button {
                    selectedGroupId = group.id
                } label: {
                    HStack {
                        if !group.color.isDefault {
                            Image(nsImage: colorDot(group.color.color))
                        }
                        Text(group.name)
                        if selectedGroupId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            // Create new group
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
            CreateGroupSheet { groupName, groupColor in
                let group = ConnectionGroup(name: groupName, color: groupColor)
                groupStorage.addGroup(group)
                selectedGroupId = group.id
                allGroups = groupStorage.loadGroups()
            }
        }
    }

    /// Create a colored circle NSImage for use in menu items
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
    let onSave: (String, ConnectionColor) -> Void

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

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Button("Create") {
                    onSave(groupName, groupColor)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onExitCommand {
            dismiss()
        }
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
