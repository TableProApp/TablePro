//
//  TableStructureView+Schema.swift
//  TablePro
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
            // An undo back to a clean state would otherwise leave the last preview's SQL behind.
            toolbarState.previewStatements = []
            return
        }

        if skipSchemaPreview {
            Task { _ = await session.applyStagedChanges(coordinator: coordinator) }
            return
        }

        guard let coordinator else { return }
        Task { await session.previewStagedChanges(coordinator: coordinator) }
    }

    func refreshAfterApply() async {
        isReloadingAfterSave = true
        await reloadCoreTabs()
        adoptFetchedBaseline()
        await loadTabDataIfNeeded(selectedTab)

        gridAdapter.refresh()

        // Left false, the next mount re-baselines the change manager and drops anything staged since.
        session.hasLoaded = true
        isReloadingAfterSave = false
    }

    func discardChanges() {
        session.gridModel.discardEditing()
        structureChangeManager.discardChanges()
        gridAdapter.refresh()
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
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .paneBarBackground()

            Divider()

            if ddlStatement.isEmpty {
                StructureDDLUnavailableView()
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

        withMotion {
            showCopyConfirmation = true
        }

        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            withMotion {
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
                Self.logger.error("Failed to export: \(error.publicLogShape, privacy: .public)")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could not export the schema"),
                    message: error.localizedDescription,
                    window: window
                )
            }
        }
    }
}

internal struct StructureDDLUnavailableView: View {
    internal var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "No DDL available"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .valueStandInBackground()
    }
}
