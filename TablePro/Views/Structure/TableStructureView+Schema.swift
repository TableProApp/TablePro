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
            return
        }

        // If user chose to skip preview, apply changes directly
        if skipSchemaPreview {
            Task {
                await executeSchemaChanges()
            }
            return
        }

        guard let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver else {
            toolbarState.previewStatements = ["-- Error: no plugin driver available for DDL generation"]
            toolbarState.showSQLReviewPopover = true
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
        toolbarState.showSQLReviewPopover = true
    }

    func executeSchemaChanges() async {
        guard !connection.safeModeLevel.blocksAllWrites else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Read-Only Connection"),
                message: String(localized: "Cannot save schema changes: connection is read-only."),
                window: NSApp.keyWindow
            )
            return
        }

        let changes = structureChangeManager.getChangesArray()
        guard !changes.isEmpty else { return }

        // Check for destructive changes that require confirmation
        let destructiveChanges = changes.filter { $0.requiresDataMigration }
        if !destructiveChanges.isEmpty {
            let descriptions = destructiveChanges.map { $0.description }
            let message = String(
                format: String(localized: "The following changes may cause data loss:\n\n%@\n\nDo you want to proceed?"),
                descriptions.joined(separator: "\n")
            )

            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Destructive Changes"),
                message: message,
                confirmButton: String(localized: "Apply Changes"),
                cancelButton: String(localized: "Cancel"),
                window: NSApp.keyWindow
            )
            guard confirmed else { return }
        }

        // Set flag BEFORE calling DatabaseManager (so we ignore its refresh notification)
        isReloadingAfterSave = true

        do {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: tableName,
                changes: changes,
                databaseType: connection.type
            )

            // Success - reload schema
            loadedTabs.removeAll()

            // Reload all structure data before calling loadSchemaForEditing
            await loadColumns()

            // Load indexes and foreign keys (needed for complete schema state)
            guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
                isReloadingAfterSave = false
                return
            }
            do {
                indexes = try await driver.fetchIndexes(table: tableName)
                loadedTabs.insert(.indexes)
                foreignKeys = try await driver.fetchForeignKeys(table: tableName)
                loadedTabs.insert(.foreignKeys)
            } catch {
                Self.logger.error("Failed to reload indexes/FKs: \(error.localizedDescription, privacy: .public)")
            }

            // Now load the complete schema into the change manager
            loadSchemaForEditing()

            // Load current tab data for display
            await loadTabDataIfNeeded(selectedTab)

            // Force clear state after reload (in case it got set during the async process)
            structureChangeManager.discardChanges()

            lastSaveTime = Date()
            isReloadingAfterSave = false
        } catch {
            isReloadingAfterSave = false  // Clear flag on error
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }

    func discardChanges() {
        structureChangeManager.discardChanges()
    }

    // MARK: - DDL View

    var ddlView: some View {
        VStack(spacing: 0) {
            // DDL toolbar
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
                            .foregroundStyle(Color(nsColor: .systemGreen))
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

        guard let window = NSApp.keyWindow else { return }
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try ddlStatement.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.logger.error("Failed to export: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
