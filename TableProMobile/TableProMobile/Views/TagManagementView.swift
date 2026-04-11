//
//  TagManagementView.swift
//  TableProMobile
//

import SwiftUI
import TableProModels

struct TagManagementView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingTag: ConnectionTag?
    @State private var showingAddTag = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.tags) { tag in
                    Button {
                        if !tag.isPreset {
                            editingTag = tag
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(ConnectionColorPicker.swiftUIColor(for: tag.color))
                                .frame(width: 12, height: 12)

                            Text(tag.name)
                                .foregroundStyle(.primary)

                            if tag.isPreset {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            let count = appState.connections.filter { $0.tagId == tag.id }.count
                            Text("\(count)")
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
                }
            }
            .overlay {
                if appState.tags.isEmpty {
                    ContentUnavailableView {
                        Label("No Tags", systemImage: "tag")
                    } description: {
                        Text("Create a tag to organize your connections.")
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
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddTag) {
                TagFormSheet { tag in
                    appState.addTag(tag)
                }
            }
            .sheet(item: $editingTag) { tag in
                TagFormSheet(editing: tag) { updated in
                    appState.updateTag(updated)
                }
            }
        }
    }
}
