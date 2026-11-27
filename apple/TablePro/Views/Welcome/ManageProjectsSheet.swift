//
//  ManageProjectsSheet.swift
//  TablePro
//

import SwiftUI

internal struct ManageProjectsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ManageProjectsViewModel
    @FocusState private var focusedProjectId: UUID?

    internal init(storage: ProjectStorage, appEvents: AppEvents) {
        _model = StateObject(wrappedValue: ManageProjectsViewModel(storage: storage, appEvents: appEvents))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects")
                .font(.headline)

            list

            if let errorMessage = model.errorMessage {
                NoticeLabel(errorMessage, severity: .error)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("A project shows only its own connections in the list, in search and in history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(String(localized: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("manage-projects-done")
            }
        }
        .padding(20)
        .frame(width: 360)
        .onExitCommand {
            dismiss()
        }
        .alert(
            String(format: String(localized: "Delete “%@”?"), model.projectPendingDeletion?.name ?? ""),
            isPresented: Binding(
                get: { model.projectPendingDeletion != nil },
                set: { if !$0 { model.projectPendingDeletion = nil } }
            )
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                model.confirmDelete()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                model.projectPendingDeletion = nil
            }
        } message: {
            Text("Its connections are kept and move to All Connections.")
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.projects) { project in
                ProjectNameRow(project: project, focusedProjectId: $focusedProjectId) { name in
                    model.rename(project.id, to: name)
                }
                .tag(project.id)
            }
            .onMove { source, destination in
                model.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: 200)
        .accessibilityLabel(String(localized: "Projects"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    AddRemoveControlGroup(
                        addLabel: String(localized: "New Project"),
                        removeLabel: String(localized: "Delete Project…"),
                        canRemove: model.selectedProject != nil,
                        addIdentifier: "manage-projects-add",
                        removeIdentifier: "manage-projects-remove",
                        onAdd: {
                            focusedProjectId = model.addProject()
                        },
                        onRemove: { model.requestDeleteSelection() }
                    )
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .background(.bar)
        }
    }
}

// The row owns the text being typed, so a name the store refuses stays on screen beside the reason.
private struct ProjectNameRow: View {
    let project: ConnectionProject
    let focusedProjectId: FocusState<UUID?>.Binding
    let onCommit: (String) -> Bool

    @State private var name: String

    init(project: ConnectionProject, focusedProjectId: FocusState<UUID?>.Binding, onCommit: @escaping (String) -> Bool) {
        self.project = project
        self.focusedProjectId = focusedProjectId
        self.onCommit = onCommit
        _name = State(initialValue: project.name)
    }

    var body: some View {
        TextField("", text: $name, prompt: Text("Project name"))
            .focused(focusedProjectId, equals: project.id)
            .accessibilityLabel(String(localized: "Project name"))
            .onSubmit(commit)
            .onChange(of: focusedProjectId.wrappedValue) { focused in
                if focused != project.id { commit() }
            }
            .onChange(of: project.name) { stored in
                name = stored
            }
    }

    private func commit() {
        guard name != project.name else { return }
        if !onCommit(name), focusedProjectId.wrappedValue != project.id {
            name = project.name
        }
    }
}
