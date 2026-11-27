//
//  ConnectionGroupPicker.swift
//  TablePro
//

import SwiftUI

struct ConnectionGroupPicker: View {
    @Binding var selectedGroupId: UUID?
    // The connection the form edits, nil for a new one.
    var connectionId: UUID?
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
        .task { reload() }
        .onReceive(ConnectionScope.shared.scopedSetChanged) { _ in reload() }
        .sheet(isPresented: $showingCreateSheet) {
            GroupEditorSheet(mode: .create(parentId: nil), groups: allGroups) { draft in
                let group = ConnectionScope.shared.placing(
                    ConnectionGroup(
                        name: draft.name,
                        color: draft.color,
                        iconName: draft.iconName,
                        parentId: draft.parentId
                    ),
                    forConnection: connectionId
                )
                try groupStorage.addGroup(group)
                selectedGroupId = group.id
                reload()
            }
        }
    }

    private func reload() {
        allGroups = Self.choices(
            forConnection: connectionId,
            selected: selectedGroupId,
            scope: .shared,
            groupStorage: groupStorage
        )
    }

    // A group chosen before the scope changed stays on show, or the pop-up would read None over it.
    @MainActor
    internal static func choices(
        forConnection connectionId: UUID?,
        selected selectedGroupId: UUID?,
        scope: ConnectionScope,
        groupStorage: GroupStorage
    ) -> [ConnectionGroup] {
        let choices = scope.groupChoices(forConnection: connectionId)
        if let selectedGroupId, !choices.contains(where: { $0.id == selectedGroupId }) {
            return groupStorage.loadGroups()
        }
        return choices
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
