//
//  StructureDDLPane.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

// The table's CREATE statement as the database reports it, read-only, with the ways to take it elsewhere.
struct StructureDDLPane: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "StructureDDLPane")

    let ddl: String
    let tableName: String
    let databaseType: DatabaseType
    let failure: String?
    let isLoading: Bool
    let coordinator: MainContentCoordinator?
    let onRetry: () -> Void

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) private var fontSize: Double = 13

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ControlGroup {
                    Button {
                        fontSize = max(10, fontSize - 1)
                    } label: {
                        Label(String(localized: "Decrease Font Size"), systemImage: "textformat.size.smaller")
                    }
                    Button {
                        fontSize = min(24, fontSize + 1)
                    } label: {
                        Label(String(localized: "Increase Font Size"), systemImage: "textformat.size.larger")
                    }
                }
                .controlGroupStyle(.navigation)
                .labelStyle(.iconOnly)
                .fixedSize()

                Spacer()

                Button(String(localized: "Open in Editor"), action: openInEditor)
                    .disabled(ddl.isEmpty)
                Button(String(localized: "Copy"), action: copy)
                    .disabled(ddl.isEmpty)
                Button(String(localized: "Export…"), action: export)
                    .disabled(ddl.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .paneBarBackground()

            Divider()

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure, ddl.isEmpty {
            UnavailableStateView {
                Label(String(localized: "Couldn't Read the DDL"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button(String(localized: "Try Again"), action: onRetry)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .valueStandInBackground()
        } else if ddl.isEmpty {
            StructureDDLStandIn(isLoading: isLoading)
        } else {
            DDLTextView(ddl: ddl, fontSize: $fontSize, databaseType: databaseType)
        }
    }

    private func openInEditor() {
        guard !ddl.isEmpty else { return }
        coordinator?.tabManager.addTab(initialQuery: ddl, title: String(format: String(localized: "%@ DDL"), tableName))
    }

    private func copy() {
        ClipboardService.shared.writeText(ddl)
    }

    private func export() {
        let savePanel = NSSavePanel()
        if let sqlType = UTType(filenameExtension: "sql") {
            savePanel.allowedContentTypes = [sqlType]
        }
        savePanel.nameFieldStringValue = "\(tableName).sql"

        guard let window = coordinator?.contentWindow else { return }
        let ddl = ddl
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try ddl.write(to: url, atomically: true, encoding: .utf8)
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

// Where the statement would be, on the editor's background.
struct StructureDDLStandIn: View {
    var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(String(localized: "No DDL Available"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .valueStandInBackground()
    }
}
