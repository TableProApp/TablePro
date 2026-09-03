//
//  ConnectionGroupPicker.swift
//  TablePro
//

import SwiftUI

struct ConnectionGroupPicker: View {
    @Binding var selectedGroupId: UUID?
    @State private var allGroups: [ConnectionGroup] = []
    @State private var showingCreateSheet = false

    private let groupStorage = GroupStorage.shared

    /// A pop up button carries the selected value, the checkmark, the menu role and the nesting
    /// for free. Hand-drawn checkmarks reported nothing to VoiceOver, and a SwiftUI `Picker`
    /// lowers every option to a plain `NSMenuItem`, discarding the depth the option carried.
    var body: some View {
        HStack(spacing: 6) {
            GroupPopUpButton(
                entries: GroupMenuEntries.forConnection(
                    groups: allGroups,
                    noneTitle: String(localized: "None")
                ),
                selection: $selectedGroupId,
                accessibilityLabel: String(localized: "Group")
            )
            .fixedSize()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Group…", systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Create New Group…"))
            .accessibilityLabel(Text("Create New Group…"))
        }
        .task { allGroups = groupStorage.loadGroups() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateGroupSheet { groupName, groupColor, parentId in
                let group = ConnectionGroup(name: groupName, color: groupColor, parentId: parentId)
                try groupStorage.addGroup(group)
                selectedGroupId = group.id
                allGroups = groupStorage.loadGroups()
            }
        }
    }
}

// MARK: - Create Group Sheet

struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groupName: String = ""
    @State private var groupColor: ConnectionColor = .none
    @State private var selectedParentId: UUID?
    @State private var allGroups: [ConnectionGroup] = []
    @State private var errorMessage: String?

    private let initialParentId: UUID?
    /// Throwing, because the store refuses a duplicate sibling name, a cycle and a group nested
    /// past the cap. A sheet that dismissed on the attempt left the caller holding the id of a
    /// group that was never saved.
    let onSave: (String, ConnectionColor, UUID?) throws -> Void

    init(parentId: UUID? = nil, onSave: @escaping (String, ConnectionColor, UUID?) throws -> Void) {
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

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    do {
                        try onSave(groupName, groupColor, selectedParentId)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: groupName) { _, _ in errorMessage = nil }
        .onChange(of: selectedParentId) { _, _ in errorMessage = nil }
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
        GroupPopUpButton(
            entries: GroupMenuEntries.forParent(
                groups: allGroups,
                noneTitle: String(localized: "None (Top Level)")
            ),
            selection: $selectedParentId,
            accessibilityLabel: String(localized: "Parent Group")
        )
        .fixedSize()
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
