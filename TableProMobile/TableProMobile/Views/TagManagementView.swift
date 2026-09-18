import SwiftUI
import TableProModels

struct TagManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingTag: ConnectionTag?
    @State private var showingAddTag = false
    @State private var tagPendingDeletion: TagDeletionRequest?

    var body: some View {
        let usage = ConnectionLibraryEditing.tagUsageCounts(in: appState.connections)
        NavigationStack {
            List {
                ForEach(appState.tags) { tag in
                    Button {
                        if !tag.isPreset {
                            editingTag = tag
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(ConnectionColorPicker.swiftUIColor(for: tag.color))
                                .accessibilityHidden(true)

                            Text(tag.name)
                                .foregroundStyle(.primary)

                            if tag.isPreset {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("\(usage[tag.id] ?? 0)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !tag.isPreset {
                            Button {
                                requestDeletion(of: tag)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                    .contextMenu {
                        if !tag.isPreset {
                            Button {
                                editingTag = tag
                            } label: {
                                Label("Edit Tag", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                requestDeletion(of: tag)
                            } label: {
                                Label("Delete Tag", systemImage: "trash")
                            }
                        }
                    }
                    .accessibilityActions {
                        if !tag.isPreset {
                            Button("Delete Tag") { requestDeletion(of: tag) }
                        }
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Delete Tag"),
                isPresented: deletionPresented,
                titleVisibility: .visible,
                presenting: tagPendingDeletion
            ) { request in
                Button(String(localized: "Delete"), role: .destructive) {
                    appState.deleteTag(request.tag.id)
                }
            } message: { request in
                Text(request.message)
            }
            .overlay {
                if appState.tags.isEmpty {
                    ContentUnavailableView {
                        Label("No Tags", systemImage: "tag")
                    } description: {
                        Text("Create a tag to organize your connections.")
                    } actions: {
                        Button("Create Tag") { showingAddTag = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingAddTag = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add Tag"))
                    CloseButton { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddTag) {
                TagFormSheet()
            }
            .sheet(item: $editingTag) { tag in
                TagFormSheet(editing: tag)
            }
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { tagPendingDeletion != nil },
            set: { if !$0 { tagPendingDeletion = nil } }
        )
    }

    private func requestDeletion(of tag: ConnectionTag) {
        tagPendingDeletion = ConnectionLibraryEditing.tagDeletionRequest(
            tag.id,
            tags: appState.tags,
            connections: appState.connections
        )
    }
}
