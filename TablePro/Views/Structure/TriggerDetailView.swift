//
//  TriggerDetailView.swift
//  TablePro
//

import Combine
import SwiftUI

@MainActor
final class TriggerInspectorState: ObservableObject {
    @Published var searchText = ""
    @Published var sortState = TriggerListColumns.defaultSort
    @Published var selectedIDs: Set<TriggerInfo.ID> = []

    func displayed(_ triggers: [TriggerInfo]) -> [TriggerInfo] {
        let filtered = searchText.isEmpty
            ? triggers
            : triggers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return TriggerListColumns.sorted(filtered, by: sortState)
    }

    func selectedTrigger(_ triggers: [TriggerInfo]) -> TriggerInfo? {
        let list = displayed(triggers)
        return list.first { selectedIDs.contains($0.id) } ?? list.first
    }

    /// Edit and Delete act on one trigger, so they have no target while several rows are selected.
    func actionTarget(_ triggers: [TriggerInfo]) -> TriggerInfo? {
        let list = displayed(triggers)
        let selected = list.filter { selectedIDs.contains($0.id) }
        guard selected.count <= 1 else { return nil }
        return selected.first ?? list.first
    }

    func select(_ ids: Set<TriggerInfo.ID>) {
        guard ids != selectedIDs else { return }
        selectedIDs = ids
    }

    func ensureSelection(_ triggers: [TriggerInfo]) {
        let kept = selectedIDs.intersection(triggers.map(\.id))
        select(kept.isEmpty ? Set(triggers.first.map { [$0.id] } ?? []) : kept)
    }
}

enum TriggerListColumns {
    static let nameColumn = 0
    static let enabledColumn = 3

    static var defaultSort: SortState {
        SortState(
            columns: [SortColumn(columnIndex: nameColumn, direction: .ascending, columnName: String(localized: "Name"))],
            source: .user
        )
    }

    static func titles(showsEnabled: Bool) -> [String] {
        let base = [String(localized: "Name"), String(localized: "Timing"), String(localized: "Event")]
        return showsEnabled ? base + [String(localized: "Enabled")] : base
    }

    internal static func widths(showsEnabled: Bool) -> [CGFloat] {
        showsEnabled ? [220, 90, 150, 70] : [240, 90, 160]
    }

    internal static func minimumWidths(showsEnabled: Bool) -> [CGFloat] {
        showsEnabled ? [140, 70, 90, 60] : [140, 70, 90]
    }

    static func values(for trigger: TriggerInfo, showsEnabled: Bool) -> [String] {
        let base = [trigger.name, trigger.timing, trigger.event]
        guard showsEnabled else { return base }
        return base + [trigger.enabled.map { $0 ? "YES" : "NO" } ?? ""]
    }

    static func spokenValues(for trigger: TriggerInfo, showsEnabled: Bool) -> [Int: String] {
        guard showsEnabled, let enabled = trigger.enabled else { return [:] }
        return [enabledColumn: enabled ? String(localized: "Enabled") : String(localized: "Disabled")]
    }

    static func sorted(_ triggers: [TriggerInfo], by state: SortState) -> [TriggerInfo] {
        guard !state.columns.isEmpty else { return triggers }
        let keyed = triggers.enumerated().map { offset, trigger in
            (offset: offset, trigger: trigger, values: values(for: trigger, showsEnabled: true))
        }
        return keyed.sorted { lhs, rhs in
            for column in state.columns where lhs.values.indices.contains(column.columnIndex) {
                let comparison = lhs.values[column.columnIndex].localizedStandardCompare(rhs.values[column.columnIndex])
                guard comparison != .orderedSame else { continue }
                return column.direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }
        .map(\.trigger)
    }
}

private struct TriggerEditorSheetItem: Identifiable {
    let id = UUID()
    let mode: TriggerEditorView.Mode
    let sql: String
}

struct TriggerDetailView: View {
    let triggers: [TriggerInfo]
    let scope: DatabaseScope
    let connection: DatabaseConnection
    let tableName: String
    let isLoading: Bool
    let canEdit: Bool
    let onOpenInEditor: (TriggerInfo) -> Void

    @StateObject private var state = TriggerInspectorState()
    @State private var editorSheet: TriggerEditorSheetItem?
    @State private var pendingDelete: TriggerInfo?
    @State private var actionError: String?

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gridStandInBackground()
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
                .gridStandInBackground()
        }
        .sheet(item: $editorSheet, content: makeEditorSheet(for:))
    }

    private var populated: some View {
        VStack(spacing: 0) {
            if canEdit {
                TriggerActionBar(triggers: triggers, state: state, canEdit: canEdit, onNew: newTrigger, onEdit: editTrigger, onDelete: { pendingDelete = $0 })
                Divider()
            }
            AutosavingSplitView(
                autosaveName: "com.TablePro.triggerSplit",
                isVertical: false,
                primaryMinimum: 120,
                secondaryMinimum: 180
            ) {
                TriggerListPane(triggers: triggers, databaseType: connection.type, state: state)
            } secondary: {
                TriggerDetailPane(triggers: triggers, state: state, databaseType: connection.type, onOpenInEditor: onOpenInEditor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.ensureSelection(triggers) }
        .onChange(of: triggers) { newTriggers in state.ensureSelection(newTriggers) }
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
            Text(verbatim: RevealedText(actionError ?? "").plainText)
        }
    }

    private func makeEditorSheet(for item: TriggerEditorSheetItem) -> some View {
        TriggerEditorView(
            scope: scope,
            connection: connection,
            tableName: tableName,
            mode: item.mode,
            initialSQL: item.sql,
            onClose: { editorSheet = nil }
        )
    }

    /// Read through the tab's own scope rather than the session driver, which follows the sidebar:
    /// an engine that qualifies its template with the connection's current database pre-fills a
    /// statement that creates the trigger on a same-named table in whatever database that is.
    private func newTrigger() {
        let scope = scope
        let tableName = tableName
        Task {
            let generated = try? await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                driver.createTriggerTemplate(table: tableName)
            }
            let template = (generated ?? nil)
                ?? "CREATE TRIGGER trigger_name\nAFTER INSERT ON \(tableName)\nBEGIN\nEND;"
            editorSheet = TriggerEditorSheetItem(mode: .create, sql: template)
        }
    }

    private func editTrigger(_ trigger: TriggerInfo) {
        Task {
            let scope = scope
            let tableName = tableName
            let name = trigger.name
            let fetched = try? await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchTriggerDefinition(name: name, table: tableName)
            }
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
                try await TriggerEditing.drop(
                    scope: scope,
                    connection: connection,
                    tableName: tableName,
                    name: trigger.name
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct TriggerActionBar: View {
    let triggers: [TriggerInfo]
    @ObservedObject var state: TriggerInspectorState
    let canEdit: Bool
    let onNew: () -> Void
    let onEdit: (TriggerInfo) -> Void
    let onDelete: (TriggerInfo) -> Void

    var body: some View {
        let target = state.actionTarget(triggers)
        HStack(spacing: 8) {
            Button(action: onNew) {
                Label("New Trigger", systemImage: "plus")
            }
            Button {
                if let target { onEdit(target) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(target == nil)
            Button {
                if let target { onDelete(target) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(target == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

internal struct TriggerListPane: View {
    internal let triggers: [TriggerInfo]
    internal let databaseType: DatabaseType
    @ObservedObject internal var state: TriggerInspectorState

    @StateObject private var grid = StructureListGridModel<TriggerInfo.ID>(
        accessibilityLabel: StructureTab.triggers.displayName
    )
    @State private var columnLayout = ColumnLayoutState()

    private var showsEnabled: Bool { triggers.contains { $0.enabled != nil } }

    internal var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $state.searchText, placeholder: String(localized: "Filter"))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            table
        }
    }

    private var table: some View {
        let showsEnabled = showsEnabled
        let inspector = state
        let rows = inspector.displayed(triggers).map { trigger in
            StructureListRow(
                id: trigger.id,
                values: TriggerListColumns.values(for: trigger, showsEnabled: showsEnabled),
                spokenValues: TriggerListColumns.spokenValues(for: trigger, showsEnabled: showsEnabled)
            )
        }
        var hasher = Hasher()
        hasher.combine(rows)
        return StructureListGrid(
            model: grid,
            columns: TriggerListColumns.titles(showsEnabled: showsEnabled),
            defaultWidths: TriggerListColumns.widths(showsEnabled: showsEnabled),
            minimumWidths: TriggerListColumns.minimumWidths(showsEnabled: showsEnabled),
            contentKey: hasher.finalize(),
            rows: { rows },
            databaseType: databaseType,
            selectedIDs: { inspector.selectedIDs },
            select: { inspector.select($0) },
            sortState: $state.sortState,
            columnLayout: $columnLayout
        )
    }
}

private struct TriggerDetailPane: View {
    let triggers: [TriggerInfo]
    @ObservedObject var state: TriggerInspectorState
    let databaseType: DatabaseType
    let onOpenInEditor: (TriggerInfo) -> Void

    var body: some View {
        if let trigger = state.selectedTrigger(triggers) {
            ObjectSourceView(
                source: trigger.definition ?? trigger.statement,
                databaseType: databaseType,
                exportFileName: exportFileName(for: trigger),
                attributes: trigger.attributes,
                onOpenInEditor: { onOpenInEditor(trigger) }
            )
        } else {
            UnavailableStateView.search(text: state.searchText)
        }
    }

    private func exportFileName(for trigger: TriggerInfo) -> String {
        DatabaseObjectRef(trigger: trigger, database: "").suggestedFileName
    }
}
