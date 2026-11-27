import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct ProjectManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingProject: ConnectionProject?
    @State private var showingAddProject = false
    @State private var projectPendingDeletion: ConnectionProject?

    var body: some View {
        let projects = appState.orderedProjects
        let scope = appState.projectScope
        let counts = Dictionary(grouping: appState.connections.compactMap { scope.effectiveProjectId(of: $0) }) { $0 }
            .mapValues(\.count)
        NavigationStack {
            List {
                ForEach(projects) { project in
                    Button {
                        editingProject = project
                    } label: {
                        HStack(spacing: 12) {
                            Text(verbatim: project.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(counts[project.id] ?? 0)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            projectPendingDeletion = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button {
                            editingProject = project
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            projectPendingDeletion = project
                        } label: {
                            Label("Delete Project…", systemImage: "trash")
                        }
                    }
                    .accessibilityActions {
                        Button("Delete Project…") { projectPendingDeletion = project }
                    }
                }
                .onMove { source, destination in
                    var ordered = projects.map(\.id)
                    ordered.move(fromOffsets: source, toOffset: destination)
                    appState.reorderProjects(ordered)
                }
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: deletionPresented,
                titleVisibility: .visible,
                presenting: projectPendingDeletion
            ) { project in
                Button(String(localized: "Delete"), role: .destructive) {
                    appState.deleteProject(project.id)
                }
            } message: { _ in
                Text("Its connections are kept and move to All Connections.")
            }
            .overlay {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "square.stack")
                    } description: {
                        if appState.areProjectsWritable {
                            Text("A project shows only its own connections in the list, in search and in Shortcuts.")
                        } else {
                            Text("TablePro could not read your projects. Nothing on this device has been changed.")
                        }
                    } actions: {
                        if appState.areProjectsWritable {
                            Button("New Project…") { showingAddProject = true }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Try Again") { appState.retryLoadIfFailed() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingAddProject = true
                    } label: {
                        Label("New Project…", systemImage: "plus")
                    }
                    .disabled(!appState.areProjectsWritable)
                    CloseButton { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddProject) {
                ProjectFormSheet()
            }
            .sheet(item: $editingProject) { project in
                ProjectFormSheet(editing: project)
            }
        }
    }

    private var deletionTitle: String {
        String(format: String(localized: "Delete “%@”?"), projectPendingDeletion?.name ?? "")
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { projectPendingDeletion != nil },
            set: { if !$0 { projectPendingDeletion = nil } }
        )
    }
}

struct ProjectFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String
    @State private var isShowingUnavailable = false
    private let existingProject: ConnectionProject?

    init(editing project: ConnectionProject? = nil) {
        existingProject = project
        _name = State(initialValue: project?.name ?? "")
    }

    private var hasChanges: Bool {
        name != (existingProject?.name ?? "")
    }

    private var problem: ProjectWriteOutcome? {
        ConnectionLibraryEditing.projectNameProblem(name, in: appState.projects, excluding: existingProject?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    if problem == .duplicateName {
                        Text(String(
                            format: String(localized: "A project named “%@” already exists."),
                            name.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .navigationTitle(existingProject != nil ? String(localized: "Rename Project") : String(localized: "New Project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesCancelButton(hasChanges: hasChanges) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Save", action: save)
                        .disabled(problem != nil)
                }
            }
            .alert("Projects Unavailable", isPresented: $isShowingUnavailable) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("TablePro could not save the project. Nothing on this device has been changed.")
            }
        }
    }

    private func save() {
        let outcome = existingProject.map { appState.renameProject($0.id, to: name) } ?? appState.addProject(named: name)
        switch outcome {
        case .applied, .unchanged:
            dismiss()
        case .refused, .missing:
            isShowingUnavailable = true
        case .emptyName, .duplicateName:
            break
        }
    }
}
