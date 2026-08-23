//
//  TableStructureView+Schema.swift
//  TablePro
//
//  Schema operations, DDL view, and DDL actions for table structure
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

// MARK: - Schema Operations

extension TableStructureView {
    func generateStructurePreviewSQL() {
        let changes = structureChangeManager.getChangesArray()
        guard !changes.isEmpty else {
            // After undo brings the working copy back to a clean state, the popover
            // would otherwise retain the last-generated SQL. Clear it so reopening
            // the popover correctly shows "no changes".
            toolbarState.previewStatements = []
            return
        }

        if skipSchemaPreview {
            Task { _ = await session.applyStagedChanges(coordinator: coordinator) }
            return
        }

        guard let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver else {
            toolbarState.previewStatements = ["-- Error: no plugin driver available for DDL generation"]
            coordinator?.activeSheet = .sqlPreview
            return
        }

        let generator = SchemaStatementGenerator(
            tableName: tableName,
            pluginDriver: pluginDriver
        )

        do {
            let schemaStatements = try generator.generate(changes: changes)
            toolbarState.previewStatements = schemaStatements.map(\.sql)
        } catch {
            toolbarState.previewStatements = ["-- Error generating SQL: \(error.localizedDescription)"]
        }
        coordinator?.activeSheet = .sqlPreview
    }

    /// The part of a save only a mounted view can do: refetch the sub-tab the user is looking at
    /// and repaint the grid. Driven by `session.appliedVersion` rather than called from the save,
    /// so it runs exactly when there is a view to run it and never otherwise.
    func refreshAfterApply() async {
        isReloadingAfterSave = true
        await reloadCoreTabs()
        loadSchemaForEditing()
        await loadTabDataIfNeeded(selectedTab)

        /// Save resets the manager (pendingChanges cleared, working state refetched from the
        /// database) but the row count is usually unchanged after a rename or a type change, so
        /// `DataGridView.updateNSView` does not call `reloadData` on its own. Ask the grid to
        /// repaint visible cells so the modified tint clears and any value the round trip changed
        /// shows its canonical post-save form.
        gridDelegate.reloadAllVisibleRows()

        /// The apply cleared this so an unmounted tab refetches on its next mount. This view has
        /// just done that refetch, so the session is loaded again. Leaving it false would make the
        /// next remount run `loadInitialData`, and `loadSchemaForEditing` re-baselines the change
        /// manager, so anything staged since the save would be discarded without a prompt.
        session.hasLoaded = true
        isReloadingAfterSave = false
    }

    func discardChanges() {
        structureChangeManager.discardChanges()
        // Mirror the save path: discard reverts working state without changing
        // row count, so the grid needs an explicit reload to drop the yellow
        // modified tint and revert any displayed value.
        gridDelegate.reloadAllVisibleRows()
    }

    // MARK: - DDL View

    var ddlView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Button(action: { ddlFontSize = max(10, ddlFontSize - 1) }) {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel(String(localized: "Decrease font size"))
                    Text("\(Int(ddlFontSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Button(action: { ddlFontSize = min(24, ddlFontSize + 1) }) {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel(String(localized: "Increase font size"))
                }
                .buttonStyle(.borderless)

                Spacer()

                if showCopyConfirmation {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Copied!")
                    }
                    .transition(.opacity)
                }

                Button(action: openInEditor) {
                    Label("Open in Editor", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .disabled(ddlStatement.isEmpty)

                Button(action: copyDDL) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(action: exportDDL) {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if ddlStatement.isEmpty {
                emptyState(String(localized: "No DDL available"))
            } else {
                DDLTextView(ddl: ddlStatement, fontSize: $ddlFontSize, databaseType: connection.type)
            }
        }
    }

    // MARK: - DDL Actions

    private func openInEditor() {
        guard !ddlStatement.isEmpty else { return }
        coordinator?.tabManager.addTab(
            initialQuery: ddlStatement,
            title: "\(tableName) DDL"
        )
    }

    func openTriggerInEditor(_ trigger: TriggerInfo) {
        guard !trigger.statement.isEmpty else { return }
        coordinator?.tabManager.addTab(
            initialQuery: trigger.statement,
            title: trigger.name
        )
    }

    private func copyDDL() {
        ClipboardService.shared.writeText(ddlStatement)

        withAnimation {
            showCopyConfirmation = true
        }

        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            withAnimation {
                showCopyConfirmation = false
            }
        }
    }

    private func exportDDL() {
        let savePanel = NSSavePanel()
        if let sqlType = UTType(filenameExtension: "sql") {
            savePanel.allowedContentTypes = [sqlType]
        }
        savePanel.nameFieldStringValue = "\(tableName).sql"

        guard let window = coordinator?.contentWindow else { return }
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try ddlStatement.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.logger.error("Failed to export: \(error.localizedDescription, privacy: .public)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could not export the schema"),
                    message: error.localizedDescription,
                    window: window
                )
            }
        }
    }
}
