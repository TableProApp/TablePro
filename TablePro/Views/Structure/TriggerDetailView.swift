//
//  TriggerDetailView.swift
//  TablePro
//
//  Read-only master-detail view of a table's triggers.
//

import SwiftUI

@Observable
final class TriggerInspectorState {
    var searchText = ""
    var sortOrder: [KeyPathComparator<TriggerInfo>] = [KeyPathComparator(\.name)]
    var selectedID: TriggerInfo.ID?

    func displayed(_ triggers: [TriggerInfo]) -> [TriggerInfo] {
        let filtered = searchText.isEmpty
            ? triggers
            : triggers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return filtered.sorted(using: sortOrder)
    }

    func selectedTrigger(_ triggers: [TriggerInfo]) -> TriggerInfo? {
        let list = displayed(triggers)
        if let id = selectedID, let match = list.first(where: { $0.id == id }) {
            return match
        }
        return list.first
    }

    func ensureSelection(_ triggers: [TriggerInfo]) {
        if selectedID == nil || !triggers.contains(where: { $0.id == selectedID }) {
            selectedID = triggers.first?.id
        }
    }
}

private struct TriggerEditorSheetItem: Identifiable {
    let id = UUID()
    let mode: TriggerEditorView.Mode
    let sql: String
}

struct TriggerDetailView: View {
    let triggers: [TriggerInfo]
    let connection: DatabaseConnection
    let tableName: String
    let isLoading: Bool
    let onOpenInEditor: (TriggerInfo) -> Void

    @State private var state = TriggerInspectorState()
    @State private var editorSheet: TriggerEditorSheetItem?
    @State private var pendingDelete: TriggerInfo?
    @State private var actionError: String?

    private var canEdit: Bool { connection.type.supportsTriggerEditing }

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if triggers.isEmpty {
            emptyState
        } else {
            populated
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            if canEdit {
                TriggerActionBar(triggers: triggers, state: state, canEdit: canEdit, onNew: newTrigger, onEdit: editTrigger, onDelete: { pendingDelete = $0 })
                Divider()
            }
            EmptyStateView.triggers()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $editorSheet, content: makeEditorSheet(for:))
    }

    private var populated: some View {
        VStack(spacing: 0) {
            if canEdit {
                TriggerActionBar(triggers: triggers, state: state, canEdit: canEdit, onNew: newTrigger, onEdit: editTrigger, onDelete: { pendingDelete = $0 })
                Divider()
            }
            AutosavingVSplitView(
                autosaveName: "com.TablePro.triggerSplit",
                topMinimumHeight: 120,
                bottomMinimumHeight: 180
            ) {
                TriggerListPane(triggers: triggers, state: state)
            } bottom: {
                TriggerDetailPane(triggers: triggers, state: state, databaseType: connection.type, onOpenInEditor: onOpenInEditor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.ensureSelection(triggers) }
        .onChange(of: triggers) { _, newTriggers in state.ensureSelection(newTriggers) }
        .sheet(item: $editorSheet, content: makeEditorSheet(for:))
        .confirmationDialog(
            String(format: String(localized: "Drop trigger “%@”?"), pendingDelete?.name ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Drop Trigger"), role: .destructive) {
                if let trigger = pendingDelete { performDelete(trigger) }
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDelete = nil }
        }
        .alert(
            String(localized: "Trigger operation failed"),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func makeEditorSheet(for item: TriggerEditorSheetItem) -> some View {
        TriggerEditorView(
            connection: connection,
            tableName: tableName,
            mode: item.mode,
            initialSQL: item.sql,
            onClose: { editorSheet = nil }
        )
    }

    private func newTrigger() {
        let driver = DatabaseManager.shared.driver(for: connection.id)
        let template = driver?.createTriggerTemplate(table: tableName)
            ?? "CREATE TRIGGER trigger_name\nAFTER INSERT ON \(tableName)\nBEGIN\nEND;"
        editorSheet = TriggerEditorSheetItem(mode: .create, sql: template)
    }

    private func editTrigger(_ trigger: TriggerInfo) {
        Task {
            let driver = DatabaseManager.shared.driver(for: connection.id)
            let fetched = try? await driver?.fetchTriggerDefinition(name: trigger.name, table: tableName)
            let sql = (fetched ?? nil) ?? trigger.statement
            editorSheet = TriggerEditorSheetItem(
                mode: .edit(originalName: trigger.name, originalDefinition: trigger.statement),
                sql: sql
            )
        }
    }

    private func performDelete(_ trigger: TriggerInfo) {
        Task {
            do {
                try await TriggerEditing.drop(connection: connection, tableName: tableName, name: trigger.name)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct TriggerActionBar: View {
    let triggers: [TriggerInfo]
    let state: TriggerInspectorState
    let canEdit: Bool
    let onNew: () -> Void
    let onEdit: (TriggerInfo) -> Void
    let onDelete: (TriggerInfo) -> Void

    var body: some View {
        let selected = state.selectedTrigger(triggers)
        HStack(spacing: 8) {
            Button(action: onNew) {
                Label("New Trigger", systemImage: "plus")
            }
            Button {
                if let selected { onEdit(selected) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selected == nil)
            Button {
                if let selected { onDelete(selected) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selected == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct TriggerListPane: View {
    let triggers: [TriggerInfo]
    @Bindable var state: TriggerInspectorState

    private var showEnabled: Bool { triggers.contains { $0.enabled != nil } }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $state.searchText, placeholder: String(localized: "Filter"))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            table
        }
    }

    @ViewBuilder
    private var table: some View {
        if showEnabled {
            Table(state.displayed(triggers), selection: $state.selectedID, sortOrder: $state.sortOrder) {
                TableColumn(String(localized: "Name"), value: \.name)
                    .width(min: 140, ideal: 220)
                TableColumn(String(localized: "Timing"), value: \.timing)
                    .width(min: 70, ideal: 90)
                TableColumn(String(localized: "Event"), value: \.event)
                    .width(min: 90, ideal: 150)
                TableColumn(String(localized: "Enabled")) { trigger in
                    enabledIndicator(trigger)
                }
                .width(min: 60, ideal: 70)
            }
        } else {
            Table(state.displayed(triggers), selection: $state.selectedID, sortOrder: $state.sortOrder) {
                TableColumn(String(localized: "Name"), value: \.name)
                    .width(min: 140, ideal: 240)
                TableColumn(String(localized: "Timing"), value: \.timing)
                    .width(min: 70, ideal: 90)
                TableColumn(String(localized: "Event"), value: \.event)
                    .width(min: 90, ideal: 160)
            }
        }
    }

    @ViewBuilder
    private func enabledIndicator(_ trigger: TriggerInfo) -> some View {
        if let enabled = trigger.enabled {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
                .accessibilityLabel(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        }
    }
}

private struct TriggerDetailPane: View {
    let triggers: [TriggerInfo]
    let state: TriggerInspectorState
    let databaseType: DatabaseType
    let onOpenInEditor: (TriggerInfo) -> Void

    @AppStorage("structureCodeFontSize") private var fontSize: Double = 13

    var body: some View {
        if let trigger = state.selectedTrigger(triggers) {
            VStack(spacing: 0) {
                toolbar(for: trigger)
                Divider()
                DDLTextView(ddl: trigger.statement, fontSize: $fontSize, databaseType: databaseType)
            }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    private func toolbar(for trigger: TriggerInfo) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button {
                    fontSize = max(10, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(String(localized: "Decrease font size"))
                Text("\(Int(fontSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Button {
                    fontSize = min(24, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(String(localized: "Increase font size"))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                onOpenInEditor(trigger)
            } label: {
                Label("Open in Editor", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)

            Button {
                ClipboardService.shared.writeText(trigger.statement)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
