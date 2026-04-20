//
//  ConnectionTagEditor.swift
//  TablePro
//
//  Tag selector dropdown for connection form
//

import SwiftUI

/// Tag selection for a connection — single Menu dropdown
struct ConnectionTagEditor: View {
    @Binding var selectedTagId: UUID?
    @State private var allTags: [ConnectionTag] = []
    @State private var showingCreateSheet = false

    private let tagStorage = TagStorage.shared

    private var selectedTag: ConnectionTag? {
        guard let id = selectedTagId else { return nil }
        return tagStorage.tag(for: id)
    }

    var body: some View {
        Menu {
            // None option
            Button {
                selectedTagId = nil
            } label: {
                HStack {
                    Text("None")
                    if selectedTagId == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Available tags
            ForEach(allTags) { tag in
                Button {
                    selectedTagId = tag.id
                } label: {
                    HStack {
                        Image(nsImage: colorDot(tag.color.color))
                        Text(tag.name)
                        if selectedTagId == tag.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            // Create new tag
            Button {
                showingCreateSheet = true
            } label: {
                Label("Create New Tag...", systemImage: "plus.circle")
            }

            // Manage tags (delete custom tags)
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
            HStack(spacing: 6) {
                if let tag = selectedTag {
                    Circle()
                        .fill(tag.color.color)
                        .frame(width: 8, height: 8)
                    Text(tag.name)
                        .foregroundStyle(.primary)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task { allTags = tagStorage.loadTags() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTagSheet { tagName, tagColor in
                let tag = ConnectionTag(name: tagName.lowercased(), isPreset: false, color: tagColor)
                tagStorage.addTag(tag)
                selectedTagId = tag.id
                allTags = tagStorage.loadTags()
            }
        }
    }

    /// Create a colored circle NSImage for use in menu items
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

    private func deleteTag(_ tag: ConnectionTag) {
        if selectedTagId == tag.id {
            selectedTagId = nil
        }
        tagStorage.deleteTag(tag)
        allTags = tagStorage.loadTags()
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
                TagColorPicker(selectedColor: $tagColor)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Button("Create") {
                    onSave(tagName, tagColor)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
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

// MARK: - Tag Color Picker

/// Color picker for tags (excludes "none" option)
private struct TagColorPicker: View {
    @Binding var selectedColor: ConnectionColor

    private var availableColors: [ConnectionColor] {
        ConnectionColor.allCases.filter { $0 != .none }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(availableColors) { color in
                Button(action: { selectedColor = color }) {
                    Circle()
                        .fill(color.color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: selectedColor == color ? 2 : 0)
                                .frame(
                                    width: 20,
                                    height: 20
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: String(localized: "Color %@"), color.rawValue))
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var tagId: UUID?

        var body: some View {
            VStack(spacing: 20) {
                ConnectionTagEditor(selectedTagId: $tagId)
                Text("Selected: \(tagId?.uuidString ?? "none")")
            }
            .padding()
            .frame(width: 400)
        }
    }

    return PreviewWrapper()
}
