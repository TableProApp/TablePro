//
//  TableStructureView.swift
//  TablePro
//

import SwiftUI

// The Structure view of a table tab: Definition, Triggers, DDL and, on ClickHouse, Parts. It draws the session and
// hands it the window's state; loading, staging and saving live in the session.
struct TableStructureView: View {
    @ObservedObject var session: StructureEditingSession
    @ObservedObject var toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator?

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            Divider()
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await session.load() }
        .onChange(of: session.pane) { pane in
            Task { await session.loadPaneIfNeeded(pane) }
        }
        .onAppear {
            session.coordinator = coordinator
            syncReadOnly()
        }
        .onChange(of: session.hasChanges) { hasChanges in
            if !hasChanges, session.settleOwedRefetch() {
                Task { await session.load() }
            }
        }
        .onChange(of: toolbarState.safeModeLevel) { _ in syncReadOnly() }
    }

    private func syncReadOnly() {
        let blocksWrites = toolbarState.safeModeLevel.blocksAllWrites
        session.editor.readOnlyReason = blocksWrites
            ? String(localized: "Safe Mode is read-only for this connection.")
            : nil
        session.editor.isReadOnly = blocksWrites
    }

    private var paneBar: some View {
        PaneTabBar(
            title: String(localized: "Structure"),
            selection: $session.pane,
            identifier: "structure-tab-picker"
        ) {
            ForEach(session.availablePanes, id: \.self) { pane in
                Text(pane.displayName).tag(pane)
            }
        }
        .overlay(alignment: .trailing) {
            if session.changeManager.isHeldForSave {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Saving Changes…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("structure-save-progress")
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch session.pane {
        case .definition:
            StructureDefinitionPage(
                editor: session.editor,
                loadState: session.loadState,
                isLoading: session.isLoadingFirstTime,
                notes: [.indexes: indexNotes],
                onRetry: { session.retry(StructureLoadState.Item($0)) }
            )
        case .triggers:
            TriggerDetailView(
                triggers: session.triggers,
                scope: session.scope,
                connection: session.connection,
                tableName: session.tableName,
                isLoading: !session.loadState.hasData(.triggers),
                failure: session.loadState.failure(.triggers),
                onRetry: { session.retry(.triggers) },
                canEdit: session.editor.context.editGate.allowsTriggerEditing,
                onOpenInEditor: openTriggerInEditor
            )
        case .ddl:
            StructureDDLPane(
                ddl: session.ddlStatement,
                tableName: session.tableName,
                databaseType: session.connection.type,
                failure: session.loadState.failure(.ddl),
                isLoading: !session.loadState.hasData(.ddl),
                coordinator: coordinator,
                onRetry: { session.retry(.ddl) }
            )
        case .parts:
            ClickHousePartsView(
                tableName: session.tableName,
                scope: session.scope,
                connection: session.connection,
                reloadToken: session.partsReloadToken
            )
        }
    }

    private var indexNotes: [StructureSectionNote] {
        var notes: [StructureSectionNote] = []
        if let note = InvalidIndexNote(indexes: session.indexes) {
            notes.append(StructureSectionNote(
                systemImage: note.systemImage, text: note.text, identifier: "structure-invalid-index-note"
            ))
        }
        if session.objectKind == .materializedView,
           let note = MaterializedViewConcurrentRefreshNote(state: session.concurrentRefresh) {
            notes.append(StructureSectionNote(
                systemImage: note.systemImage, text: note.text, identifier: "structure-concurrent-refresh-note"
            ))
        }
        return notes
    }

    private func openTriggerInEditor(_ trigger: TriggerInfo) {
        guard !trigger.statement.isEmpty else { return }
        coordinator?.tabManager.addTab(initialQuery: trigger.statement, title: trigger.name)
    }
}
