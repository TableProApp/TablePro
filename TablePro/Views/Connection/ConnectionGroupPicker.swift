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
            GroupEditorSheet(mode: .create(parentId: nil), groups: allGroups) { draft in
                let group = ConnectionGroup(
                    name: draft.name,
                    color: draft.color,
                    iconName: draft.iconName,
                    parentId: draft.parentId
                )
                try groupStorage.addGroup(group)
                selectedGroupId = group.id
                allGroups = groupStorage.loadGroups()
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
