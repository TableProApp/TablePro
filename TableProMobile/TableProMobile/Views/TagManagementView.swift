import SwiftUI
import TableProModels

struct TagManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingTag: ConnectionTag?
    @State private var showingAddTag = false

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
                            Button(role: .destructive) {
                                appState.deleteTag(tag.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .accessibilityAction(named: Text("Delete tag")) {
                        guard !tag.isPreset else { return }
                        appState.deleteTag(tag.id)
                    }
                }
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
}
