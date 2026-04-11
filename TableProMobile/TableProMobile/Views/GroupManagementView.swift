//
//  GroupManagementView.swift
//  TableProMobile
//

import SwiftUI
import TableProModels

struct GroupManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingGroup: ConnectionGroup?
    @State private var showingAddGroup = false
    @State private var groupToDelete: ConnectionGroup?

    private var showDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.groups.sorted(by: { $0.sortOrder < $1.sortOrder })) { group in
                    Button {
                        editingGroup = group
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(ConnectionColorPicker.swiftUIColor(for: group.color))
                                .frame(width: 12, height: 12)

                            Text(group.name)
                                .foregroundStyle(.primary)

                            Spacer()

                            let count = appState.connections.filter { $0.groupId == group.id }.count
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            groupToDelete = group
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .onMove { source, destination in
                    var sorted = appState.groups.sorted(by: { $0.sortOrder < $1.sortOrder })
                    sorted.move(fromOffsets: source, toOffset: destination)
                    for index in sorted.indices {
                        sorted[index].sortOrder = index
                    }
                    appState.reorderGroups(sorted)
                }
            }
            .overlay {
                if appState.groups.isEmpty {
                    ContentUnavailableView {
                        Label("No Groups", systemImage: "folder")
                    } description: {
                        Text("Create a group to organize your connections.")
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Delete Group"),
                isPresented: showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let group = groupToDelete {
                        appState.deleteGroup(group.id)
                    }
                }
            } message: {
                Text("Connections in this group will be moved to ungrouped.")
            }
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button {
                        showingAddGroup = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddGroup) {
                GroupFormSheet { group in
                    appState.addGroup(group)
                }
            }
            .sheet(item: $editingGroup) { group in
                GroupFormSheet(editing: group) { updated in
                    appState.updateGroup(updated)
                }
            }
        }
    }
}
