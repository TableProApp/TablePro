//
//  StructureDefinitionPage.swift
//  TablePro
//

import AppKit
import SwiftUI

// Columns, indexes, foreign keys and check constraints on one scrolling page, each section with its own add and
// remove beneath it, the way Xcode's model editor stacks an entity's parts. The selected definition's full form is
// in the inspector.
struct StructureDefinitionPage: View {
    @ObservedObject var editor: StructureDefinitionEditor
    let loadState: StructureLoadState
    var isLoading = false
    var notes: [StructureSection: [StructureSectionNote]] = [:]
    var header: AnyView?
    var onRetry: (StructureSection) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gridStandInBackground()
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let header {
                            header
                        }
                        ForEach(editor.sections, id: \.self) { section in
                            StructureSectionView(
                                section: section,
                                editor: editor,
                                model: editor.adapter(for: section).model,
                                failure: loadState.failure(StructureLoadState.Item(section)),
                                hasData: editor.context.isCreatingTable || loadState.hasData(StructureLoadState.Item(section)),
                                notes: notes[section] ?? [],
                                onRetry: { onRetry(section) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .gridStandInBackground()
            }
        }
    }

    private var filterBar: some View {
        NativeSearchField(
            text: $editor.searchText,
            placeholder: String(localized: "Filter"),
            accessibilityIdentifier: "structure-filter"
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct StructureSectionNote: Equatable, Identifiable {
    let systemImage: String
    let text: String
    let identifier: String

    var id: String { identifier }
}

struct StructureSectionView: View {
    let section: StructureSection
    @ObservedObject var editor: StructureDefinitionEditor
    @ObservedObject var model: DataGridModel
    let failure: String?
    let hasData: Bool
    let notes: [StructureSectionNote]
    let onRetry: () -> Void

    private var adapter: StructureSectionAdapter { editor.adapter(for: section) }
    private var isExpanded: Bool { editor.isExpanded(section) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if isExpanded {
                content
            }
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("structure-section-\(section.rawValue)")
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            DisclosureTriangle(
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { editor.setExpanded(section, $0) }
                ),
                label: section.displayName
            )
            Text(section.displayName)
                .font(.headline)
            if hasData {
                Text(editor.count(of: section), format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { editor.setExpanded(section, !isExpanded) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var content: some View {
        if let failure, !hasData {
            failureRow(failure)
        } else {
            if let failure {
                failureRow(failure)
            }
            if adapter.visibleRowCount > 0 {
                DataGridView(model: model)
            } else {
                emptyRow
            }
            ForEach(notes) { note in
                Label(note.text, systemImage: note.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .accessibilityIdentifier(note.identifier)
            }
            footer
        }
    }

    private var emptyRow: some View {
        Text(emptyText)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private var emptyText: String {
        guard editor.searchText.isEmpty else { return String(localized: "No Matches") }
        switch section {
        case .columns: return String(localized: "No Columns")
        case .indexes: return String(localized: "No Indexes")
        case .foreignKeys: return String(localized: "No Foreign Keys")
        case .checkConstraints: return String(localized: "No Check Constraints")
        }
    }

    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(String(localized: "Try Again"), action: onRetry)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        let labels = StructureFooterPolicy.labels(for: section)
        let reason = editor.refusal(adding: section)
        return AddRemoveControlGroup(
            addLabel: labels.add,
            removeLabel: labels.remove,
            canAdd: editor.canAdd(section),
            canRemove: editor.canRemoveSelection(in: section),
            addHelp: reason,
            removeHelp: reason,
            addIdentifier: "structure-\(section.rawValue)-add",
            removeIdentifier: "structure-\(section.rawValue)-remove",
            onAdd: { editor.add(section) },
            onRemove: { editor.removeSelection(in: section) }
        )
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

// The stock disclosure triangle, the control the HIG names for showing and hiding a section's details.
struct DisclosureTriangle: NSViewRepresentable {
    @Binding var isExpanded: Bool
    let label: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.bezelStyle = .disclosure
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = isExpanded ? .on : .off
        button.setAccessibilityLabel(label)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: DisclosureTriangle

        init(parent: DisclosureTriangle) {
            self.parent = parent
        }

        @objc func toggle(_ sender: NSButton) {
            parent.isExpanded = sender.state == .on
        }
    }
}
