//
//  CompareDetailView.swift
//  TablePro
//
//  The right-hand pane: the definition of the selected object, the rows of the
//  selected table, or the script the whole comparison would run.
//
//  All three are reachable at any time. Nothing here is a step, so a user who
//  wants to see the script before choosing what to include can.
//

import SwiftUI

internal struct CompareDetailView: View {
    @Bindable internal var session: CompareSyncSession
    internal let onCompare: () -> Void
    internal let onGenerateScript: () -> Void

    internal var body: some View {
        VStack(spacing: 0) {
            paneSelector
            Divider()
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        /// Without an infinite frame the stack sizes to its content and the split view centres the
        /// whole block, which put the pane switcher halfway down an empty pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var paneSelector: some View {
        Picker(String(localized: "Detail"), selection: $session.detailPane) {
            ForEach(CompareDetailPane.allCases, id: \.self) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch session.detailPane {
        case .definitions:
            CompareDefinitionsPane(session: session)
        case .rows:
            CompareRowDiffPane(session: session, onCompare: onCompare)
        case .script:
            CompareScriptPane(session: session, onGenerateScript: onGenerateScript)
        }
    }
}

internal struct CompareDefinitionsPane: View {
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        if let result = session.selectedResult {
            ScrollView {
                definitionBody(result)
            }
        } else if session.mode == .data {
            ContentUnavailableView {
                Label("Definitions Compare Structure", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Switch the comparison to Structure to see definitions.")
            }
        } else {
            ContentUnavailableView {
                Label("No Object Selected", systemImage: "doc.text")
            } description: {
                Text("Select an object to see its definition on both sides.")
            }
        }
    }

    private func definitionBody(_ result: CompareObjectResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = result.comparisonError {
                Label {
                    Text(error)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(CompareStatusStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            StructureDefinitionDiffView(
                sourceLines: result.sourceDefinition,
                targetLines: result.targetDefinition
            )

            if !result.changes.isEmpty {
                changesSection(result.changes)
            }

            if !result.notes.isEmpty {
                notesSection(result.notes)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changesSection(_ changes: [SchemaChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                Label {
                    Text(change.description)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: change.isDestructive ? "exclamationmark.triangle.fill" : "pencil")
                }
                .foregroundStyle(changeTint(change))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notesSection(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.subheadline.weight(.semibold))
            ForEach(notes, id: \.self) { note in
                Label {
                    Text(note)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeTint(_ change: SchemaChange) -> Color {
        guard change.isDestructive else { return .primary }
        return CompareStatusStyle.warning
    }
}
