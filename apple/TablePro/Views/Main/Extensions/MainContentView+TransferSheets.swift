//
//  MainContentView+TransferSheets.swift
//  TablePro
//

import SwiftUI

// Apart from `sheetContent(for:)`, which they made more than twice as long.
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
                        ?? .tables(
                            fromSidebarSelection: coordinator.windowSidebarState.selectedTables,
                            grouping: PluginManager.shared.databaseGroupingStrategy(for: connection.type)
                        )
                ),
                sidebarTables: tables,
                initialFormatId: coordinator.exportFormatId,
                sheetWork: coordinator.sheetWork
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
                        ),
                        sheetWork: coordinator.sheetWork
                    )
                } else {
                    ExportDialog(
                        isPresented: dismissBinding,
                        mode: .queryResults(
                            connection: connectionWithCurrentDatabase,
                            tableRows: coordinator.tabSessionRegistry.tableRows(for: tab.id),
                            suggestedFileName: fileName,
                            fillUnloaded: coordinator.unloadedValueFill(for: tab)
                        ),
                        sheetWork: coordinator.sheetWork
                    )
                }
            }
        case .exportDataSource(let request):
            ExportDialog(
                isPresented: dismissBinding,
                mode: .dataSource(request),
                sheetWork: coordinator.sheetWork
            )
        case .importDialog(let formatId):
            ImportDialog(
                isPresented: dismissBinding,
                connection: connection,
                initialFileURL: coordinator.importFile?.url,
                initialFormatId: formatId
            )
        case .rowImport(let formatId):
            if let handoff = coordinator.importFile {
                RowImportSheet(
                    isPresented: dismissBinding,
                    connection: connection,
                    fileURL: handoff.url,
                    sourceName: handoff.sourceName,
                    formatId: formatId
                )
            }
        case .rowImportBatch:
            if let batch = coordinator.importBatch {
                RowImportBatchSheet(
                    isPresented: dismissBinding,
                    connection: connection,
                    files: batch.files,
                    leftOut: batch.leftOut
                )
            }
        case .transferTables(let tables, let schema):
            transferSheet(tables: tables, schema: schema, dismiss: dismissBinding)
        case .backupDatabase(let databases):
            BackupDatabaseFlow(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialDatabase: DatabaseManager.shared.session(for: connection.id)?.browseDatabase
                    ?? connection.database,
                preselectedDatabases: databases
            )
        case .restoreDatabase(let fileURL):
            RestoreDatabaseFlow(
                isPresented: dismissBinding,
                connection: connectionWithCurrentDatabase,
                initialDatabase: DatabaseManager.shared.session(for: connection.id)?.browseDatabase
                    ?? connection.database,
                sourceURL: fileURL
            )
        default:
            EmptyView()
        }
    }
}
