//
//  MainContentView+TransferSheets.swift
//  TablePro
//

import SwiftUI

/// The sheets that move data in or out of a connection: export, import, transfer, backup, restore
/// and server-side export. They live apart from the rest because together they were more than half
/// of what `sheetContent(for:)` had to hold.
extension MainContentView {
    @ViewBuilder
    func transferSheetContent(for sheet: ActiveSheet, dismiss dismissBinding: Binding<Bool>) -> some View {
        switch sheet {
        case .exportDialog:
            let exportConnection = exportConnection
            ExportDialog(
                isPresented: dismissBinding,
                mode: .tables(
                    connection: exportConnection,
                    preselection: coordinator.exportPreselection
                        ?? .tables(Set(coordinator.windowSidebarState.selectedTables.map(\.table.name)))
                ),
                sidebarTables: tables
            )
        case .exportQueryResults:
            if let tab = coordinator.tabManager.selectedTab {
                let fileName = tab.tableContext.tableName ?? "query_results"
                if tab.pagination.hasMoreRows, let baseQuery = tab.pagination.baseQueryForMore {
                    ExportDialog(
                        isPresented: dismissBinding,
                        mode: .streamingQuery(
                            connection: connectionWithCurrentDatabase,
                            query: baseQuery,
                            suggestedFileName: fileName
                        )
                    )
                } else {
                    ExportDialog(
                        isPresented: dismissBinding,
                        mode: .queryResults(
                            connection: connectionWithCurrentDatabase,
                            tableRows: coordinator.tabSessionRegistry.tableRows(for: tab.id),
                            suggestedFileName: fileName
                        )
                    )
                }
            }
        case .importDialog(let formatId):
            let importDismiss = Binding<Bool>(
                get: { coordinator.activeSheet != nil },
                set: { if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.importFileURL = nil
                }
                }
            )
            ImportDialog(
                isPresented: importDismiss,
                connection: connection,
                initialFileURL: coordinator.importFileURL,
                initialFormatId: formatId
            )
        case .rowImport(let formatId):
            let rowDismiss = Binding<Bool>(
                get: { coordinator.activeSheet != nil },
                set: { if !$0 {
                    coordinator.activeSheet = nil
                    coordinator.importFileURL = nil
                }
                }
            )
            if let url = coordinator.importFileURL {
                RowImportSheet(
                    isPresented: rowDismiss,
                    connection: connection,
                    fileURL: url,
                    formatId: formatId
                )
            }
        case .transferTables(let tables):
            transferSheet(tables: tables, dismiss: dismissBinding)
        case .backupDatabase:
            BackupDatabaseFlow(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialDatabase: DatabaseManager.shared.session(for: connection.id)?.browseDatabase
                    ?? connection.database
            )
        case .restoreDatabase(let fileURL):
            RestoreDatabaseFlow(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialDatabase: DatabaseManager.shared.session(for: connection.id)?.browseDatabase
                    ?? connection.database,
                sourceURL: fileURL
            )
        case .serverSideExport(let table):
            ServerSideExportSheet(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialTable: table
            )
        default:
            EmptyView()
        }
    }
}
