//
//  ConnectionTagEditor.swift
//  TablePro
//

import SwiftUI

struct ConnectionTagEditor: View {
    @Binding var tagIds: [UUID]
    @State private var allTags: [ConnectionTag] = []
    @State private var showingCreateSheet = false

    private let tagStorage = TagStorage.shared

    private var selectedTags: [ConnectionTag] {
        tagIds.compactMap { id in allTags.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 6) {
            selectionView
            tagMenu
        }
        .task { allTags = tagStorage.loadTags() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTagSheet { tagName, tagColor in
                let tag = ConnectionTag(name: tagName.lowercased(), isPreset: false, color: tagColor)
                tagStorage.addTag(tag)
                allTags = tagStorage.loadTags()
                if let added = allTags.first(where: { $0.name == tag.name }) {
                    toggleOn(added.id)
                }
            }
        }
    }

    @ViewBuilder
    private var selectionView: some View {
        if selectedTags.isEmpty {
            Text("Add tags")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(selectedTags) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    private func tagChip(_ tag: ConnectionTag) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tag.color.color)
                .frame(width: 7, height: 7)
            Text(tag.name)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(tag.color.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tag.color.color.opacity(0.35), lineWidth: 1))
    }

    private var tagMenu: some View {
        Menu {
            ForEach(allTags) { tag in
                Button {
                    toggle(tag)
                } label: {
                    HStack {
                        Image(nsImage: colorDot(tag.color.color))
                        Text(tag.name)
                        if tagIds.contains(tag.id) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Tag...", systemImage: "plus.circle")
            }

            if allTags.contains(where: { !$0.isPreset }) {
                Divider()

                Menu("Manage Tags") {
                    ForEach(allTags.filter { !$0.isPreset }) { tag in
                        Button(role: .destructive) {
                            deleteTag(tag)
                        } label: {
                            Label("Delete \"\(tag.name)\"", systemImage: "trash")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func toggle(_ tag: ConnectionTag) {
        if tagIds.contains(tag.id) {
            tagIds = tagIds.filter { $0 != tag.id }
        } else {
            toggleOn(tag.id)
        }
    }

    private func toggleOn(_ id: UUID) {
        guard !tagIds.contains(id) else { return }
        var ids = tagIds
        ids.append(id)
        tagIds = ids
    }

    private func deleteTag(_ tag: ConnectionTag) {
        tagIds = tagIds.filter { $0 != tag.id }
        tagStorage.deleteTag(tag, clearingFrom: .shared)
        allTags = tagStorage.loadTags()
    }

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

// MARK: - Create Tag Sheet

private struct CreateTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tagName: String = ""
    @State private var tagColor: ConnectionColor = .gray
    let onSave: (String, ConnectionColor) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Tag")
                .font(.headline)

            TextField("Tag name", text: $tagName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ColorPaletteView(selectedColor: $tagColor, includesNone: false, size: .compact)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onSave(tagName, tagColor)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onExitCommand {
            dismiss()
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var tagIds: [UUID] = []

        var body: some View {
            VStack(spacing: 20) {
                ConnectionTagEditor(tagIds: $tagIds)
                Text("Selected: \(tagIds.count)")
            }
            .padding()
            .frame(width: 400)
        }
    }

    return PreviewWrapper()
}
