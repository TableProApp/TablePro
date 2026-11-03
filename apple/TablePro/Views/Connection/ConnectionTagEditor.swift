//
//  ConnectionTagEditor.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

// Tags are a set the person names, so they edit as tokens: type to complete or create one, Delete to
// remove one. The pull-down beside it keeps the tag colors, creation with a color and deletion.
struct ConnectionTagEditor: View {
    @Binding var tagIds: [UUID]
    @State private var allTags: [ConnectionTag] = []
    @State private var showingCreateSheet = false

    private let tagStorage = TagStorage.shared
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionTagEditor")

    private var selectedTags: [ConnectionTag] {
        tagIds.compactMap { id in allTags.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 6) {
            ConnectionTagTokenField(
                tokens: selectedTags.map(\.name),
                completions: allTags.map(\.name),
                onChange: applyTokens
            )
            tagMenu
        }
        .task { allTags = tagStorage.loadTags() }
        .sheet(isPresented: $showingCreateSheet) {
            CreateTagSheet { tagName, tagColor in
                let tag = ConnectionTag(name: tagName.lowercased(), isPreset: false, color: tagColor)
                try tagStorage.addTag(tag)
                allTags = tagStorage.loadTags()
                toggleOn(tag.id)
            }
        }
    }

    // Resolves against the store as it is now: another window or iCloud may have added a tag since
    // this form loaded. Returns the names that ended up selected, so the field drops one that failed.
    private func applyTokens(_ names: [String]) -> [String] {
        allTags = tagStorage.loadTags()
        let ids: [UUID] = ConnectionTagTokens.resolve(names, among: allTags).compactMap { entry in
            switch entry {
            case .existing(let id):
                return id
            case .new(let name):
                return createTag(named: name)
            }
        }
        allTags = tagStorage.loadTags()
        if ids != tagIds { tagIds = ids }
        return ids.compactMap { id in allTags.first { $0.id == id }?.name }
    }

    private func createTag(named name: String) -> UUID? {
        let tag = ConnectionTag(name: name, isPreset: false, color: .gray)
        do {
            try tagStorage.addTag(tag)
            return tag.id
        } catch TagStorageError.duplicateName {
            return tagStorage.loadTags().first { $0.name.lowercased() == name }?.id
        } catch {
            Self.logger.error("Could not create a tag from the token field: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    private var tagMenu: some View {
        Menu {
            ForEach(allTags) { tag in
                Button {
                    toggle(tag)
                } label: {
                    HStack {
                        Image(nsImage: Self.tagSymbol(tag.color))
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
                Label("Create New Tag…", systemImage: "plus.circle")
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
            Image(systemName: "tag")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .help(Text("Choose Tags"))
        // An icon-only pull-down publishes no name of its own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Choose Tags"))
        .accessibilityIdentifier("connection-form-tags")
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

    // A menu draws a SwiftUI symbol as a template and drops its tint, so the colored tag is an image.
    private static func tagSymbol(_ color: ConnectionColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [NSColor(color.color)])
        let image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

// MARK: - Create Tag Sheet

private struct CreateTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tagName: String = ""
    @State private var tagColor: ConnectionColor = .gray
    @State private var errorMessage: String?
    /// Throwing, because the library refuses a name it already holds. A sheet that dismissed on the
    /// attempt applied the tag that was already there, with its colour rather than the one just
    /// picked, and said nothing about the difference.
    let onSave: (String, ConnectionColor) throws -> Void

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

            if let errorMessage {
                NoticeLabel(errorMessage, severity: .error)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    do {
                        try onSave(tagName, tagColor)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: tagName) { _ in errorMessage = nil }
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
