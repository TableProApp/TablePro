//
//  CreateTableView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

// A Create Table tab: the Structure tab's Definition page over an empty table, with the name on top, and the
// CREATE statement it composes. Create Table runs from the toolbar and Cmd+S; the table options are in the inspector.
struct CreateTableView: View {
    @ObservedObject var draft: CreateTableDraft
    let coordinator: MainContentCoordinator?

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) private var ddlFontSize: Double = 13

    private static let compositionPause: Duration = .milliseconds(150)

    var body: some View {
        VStack(spacing: 0) {
            if draft.hasResolvedForm {
                paneBar
                Divider()
                paneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .navigationTitle(String(localized: "Create Table"))
        .onAppear {
            draft.prepare(coordinator: coordinator)
            publishReadiness()
        }
        .onDisappear {
            // Guarded: the outgoing view's onDisappear can land after the incoming one's onAppear.
            if let active = coordinator?.activeCreateTableDraft, active !== draft { return }
            coordinator?.toolbarState.hasCreateTablePending = false
        }
        .onChange(of: draft.isReadyToCreate) { _ in publishReadiness() }
        .task(id: draft.scope) { await draft.loadTableOptions() }
        .task(id: draft.compositionKey) { await recomposeAfterPause() }
    }

    private func publishReadiness() {
        coordinator?.toolbarState.hasCreateTablePending = draft.isReadyToCreate
    }

    private func recomposeAfterPause() async {
        try? await Task.sleep(for: Self.compositionPause)
        guard !Task.isCancelled else { return }
        await draft.recompose()
    }

    // MARK: - Panes

    private var paneBar: some View {
        PaneTabBar(
            title: String(localized: "Structure"),
            selection: paneSelection,
            identifier: "create-table-tabs"
        ) {
            ForEach(CreateTablePane.allCases, id: \.self) { pane in
                Text(title(of: pane)).tag(pane)
            }
        }
    }

    // An open cell edit lands before the pane changes, so the DDL includes it.
    private var paneSelection: Binding<CreateTablePane> {
        Binding(
            get: { draft.pane },
            set: { pane in
                draft.commitOpenEdits()
                draft.pane = pane
            }
        )
    }

    private func title(of pane: CreateTablePane) -> String {
        switch pane {
        case .definition:
            if draft.form == nil {
                return String(localized: "Definition")
            }
            return String(localized: "Form")
        case .ddl:
            return "DDL"
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch draft.pane {
        case .definition:
            if draft.form != nil {
                VStack(spacing: 0) {
                    CreateTableNameHeader(draft: draft)
                    Divider()
                    CreateTableFormView(draft: draft)
                }
            } else {
                StructureDefinitionPage(
                    editor: draft.editor,
                    loadState: StructureLoadState(),
                    header: AnyView(CreateTableNameHeader(draft: draft))
                )
            }
        case .ddl:
            ddlPane
        }
    }

    @ViewBuilder
    private var ddlPane: some View {
        if let preview = draft.formPreview {
            CreateTableFormPreview(preview: preview, databaseType: draft.connection.type)
        } else if let composed = draft.composed {
            if composed.statements.isEmpty {
                CreateTableSQLPreviewStandIn(content: .message(composed.issues.first?.qualifiedMessage))
            } else {
                DDLTextView(ddl: composed.preview, fontSize: $ddlFontSize, databaseType: draft.connection.type)
            }
        } else if let failure = draft.compositionFailure {
            CreateTableSQLPreviewStandIn(content: .message(failure))
        } else {
            let plan = draft.plan()
            CreateTableSQLPreviewStandIn(
                content: plan.definition == nil ? .message(plan.issues.first?.qualifiedMessage) : .composing
            )
        }
    }
}

// The table's name and what still stands between the draft and Create Table. An issue that names a row reveals it.
struct CreateTableNameHeader: View {
    @ObservedObject var draft: CreateTableDraft
    @FocusState private var isNameFocused: Bool

    private struct Row: Identifiable {
        let id: String
        let message: String
        let reveal: (() -> Void)?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Table Name:")
                TextField(String(localized: "Table Name"), text: $draft.tableName, prompt: Text("Required"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .frame(maxWidth: 300)
                    .focused($isNameFocused)
                    .accessibilityIdentifier("create-table-name")
            }
            let issueRows = rows
            if !issueRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issueRows) { row in
                        issueRow(row)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("create-table-validation")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if draft.claimNameFocus() {
                isNameFocused = true
            }
        }
    }

    private func issueRow(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let reveal = row.reveal {
                Button(row.message, action: reveal)
                    .buttonStyle(.link)
            } else {
                Text(row.message)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rows: [Row] {
        if let form = draft.form {
            let messages = [form.submissionError?.message].compactMap { $0 }
                + form.issues(tableName: draft.tableName).map(\.qualifiedMessage)
            return messages.enumerated().map { Row(id: "\($0.offset)", message: $0.element, reveal: nil) }
        }
        return draft.issues.enumerated().map { offset, issue in
            Row(
                id: "\(offset)-\(issue.id)",
                message: issue.row == nil ? issue.message : issue.qualifiedMessage,
                reveal: draft.entityID(for: issue) == nil ? nil : { draft.reveal(issue) }
            )
        }
    }
}

internal struct CreateTableSQLPreviewStandIn: View {
    internal enum Content: Equatable {
        case message(String?)
        case composing
    }

    internal let content: Content

    internal var body: some View {
        stateView
            .valueStandInBackground()
    }

    @ViewBuilder
    private var stateView: some View {
        switch content {
        case .message(let message):
            VStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message ?? String(localized: "Add columns to see the CREATE TABLE statement"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .composing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
