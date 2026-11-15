import SwiftUI
import TableProConnectionLibrary
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import UniformTypeIdentifiers

struct TableListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinator.self) private var coordinator

    private var connection: DatabaseConnection { coordinator.connection }
    private var tables: [TableInfo] { coordinator.tables }
    private var session: ConnectionSession? { coordinator.session }

    private var activeSchema: String? {
        coordinator.supportsSchemas ? coordinator.activeSchema : nil
    }

    /// Truncate and Drop write literal `TRUNCATE TABLE` / `DROP TABLE` below, so they are only
    /// offered where that is a statement the engine could run. On Redis the rows are keys and the
    /// driver tokenises the text as a Redis command, so `DROP TABLE "session:42"` came back as an
    /// unknown command after promising a delete.
    private var engineSpeaksSQLDDL: Bool {
        SQLDDLFallbackPolicy.allowsGeneratedDDL(databaseTypeId: connection.type.rawValue)
    }

    /// Scoped to the connection: one shared key leaves a filter from another connection applied
    /// to a list that never shows it.
    @SceneStorage private var searchText: String

    init(connectionId: UUID) {
        _searchText = SceneStorage(wrappedValue: "", "tableList.searchText.\(connectionId.uuidString)")
    }

    @FocusState private var searchFocused: Bool
    @State private var tableToTruncate: PendingTableAction?
    @State private var tableToDrop: PendingTableAction?
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var exportItem: MobileExportItem?
    @State private var showFilePicker = false
    @State private var filePickerTypes: [UTType] = []
    @State private var importFile: IdentifiableURL?

    private var canExport: Bool {
        session.map { ExportObjectListing.supportsExport($0.driver) } ?? false
    }

    // Read-Only hides what writes; Confirm Writes asks when the import starts.
    private var writesAllowed: Bool {
        !connection.safeModeLevel.blocksWrites && canExport
    }

    private var importFormats: [any ImportFormatPlugin] {
        guard writesAllowed else { return [] }
        let rows = MobileImportFormats.rowFormats(for: connection.type)
        return MobileImportFormats.offersSQLFile(for: connection.type) ? rows + [MobileImportFormats.sql] : rows
    }

    private var canRunSQLFile: Bool {
        writesAllowed && MobileImportFormats.offersSQLFile(for: connection.type)
    }

    private var exportDatabase: String? {
        coordinator.activeDatabase.isEmpty ? nil : coordinator.activeDatabase
    }

    private var exportSchema: String? {
        coordinator.supportsSchemas ? coordinator.activeSchema : nil
    }

    private var showTruncateConfirmation: Binding<Bool> {
        Binding(
            get: { tableToTruncate != nil },
            set: { if !$0 { tableToTruncate = nil } }
        )
    }

    private var showDropConfirmation: Binding<Bool> {
        Binding(
            get: { tableToDrop != nil },
            set: { if !$0 { tableToDrop = nil } }
        )
    }

    private var filteredTables: [TableInfo] {
        let filtered = searchText.isEmpty ? tables : tables.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return filtered
    }

    /// Grouped by the kind's own answer rather than by two `==` filters, so a kind this list does
    /// not name cannot fall through both and disappear, which is what a MariaDB sequence did.
    private var tableSections: [(String, [TableInfo])] {
        let grouped = Dictionary(grouping: filteredTables, by: \.type.listSection)
        return TableInfo.TableKind.ListSection.allCases.compactMap { section in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            return (Self.sectionTitle(section), items)
        }
    }

    private static func sectionTitle(_ section: TableInfo.TableKind.ListSection) -> String {
        switch section {
        case .tables: return String(localized: "Tables")
        case .views: return String(localized: "Views")
        }
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        return List(selection: $coordinator.selectedTable) {
            ForEach(tableSections, id: \.0) { sectionTitle, items in
                Section {
                    ForEach(items) { table in
                        TableRow(table: table)
                        .tag(table)
                        .contextMenu {
                            Button {
                                ClipboardExporter.copyToClipboard(table.name)
                            } label: {
                                Label("Copy Name", systemImage: "doc.on.doc")
                            }

                            if canExport {
                                Button {
                                    presentExport(of: table)
                                } label: {
                                    Label("Export…", systemImage: "square.and.arrow.up")
                                }
                            }

                            let writesAllowed = !connection.safeModeLevel.blocksWrites && engineSpeaksSQLDDL
                            if writesAllowed && (table.type.allowsTruncate || table.type.allowsDrop) {
                                Divider()

                                if table.type.allowsTruncate {
                                    Button(role: .destructive) {
                                        tableToTruncate = PendingTableAction(table: table, placement: coordinator.tablePlacement)
                                    } label: {
                                        Label("Truncate Table", systemImage: "trash.slash")
                                    }
                                }

                                if table.type.allowsDrop {
                                    Button(role: .destructive) {
                                        tableToDrop = PendingTableAction(table: table, placement: coordinator.tablePlacement)
                                    } label: {
                                        Label("Drop Table", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .hoverEffect()
                    }
                } header: {
                    HStack {
                        Text(sectionTitle)
                        Spacer()
                        Text("\(items.count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar { transferMenu }
        .sheet(item: $exportItem) { item in
            MobileExportSheet(
                input: item.input,
                environment: .live(connectionManager: appState.connectionManager, coordinator: coordinator)
            )
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: filePickerTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importFile = IdentifiableURL(url: url)
        }
        .sheet(item: $importFile) { item in
            MobileImportSheet(fileURL: item.url) {
                Task { await coordinator.refreshTables() }
            }
            .environment(appState)
            .environment(coordinator)
        }
        .searchable(text: $searchText, prompt: "Search tables")
        .searchFocused($searchFocused)
        .textInputAutocapitalization(.never)
        .refreshable {
            await coordinator.refreshTables()
        }
        .onAppear {
            coordinator.navigateToPendingTable()
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel(Text("Focus search"))
                .hidden()
        }
        .overlay {
            if tables.isEmpty {
                ContentUnavailableView(
                    "No Tables",
                    systemImage: "tablecells",
                    description: Text("This database has no tables.")
                )
            } else if filteredTables.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .confirmationDialog(
            String(localized: "Truncate Table"),
            isPresented: showTruncateConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Truncate"), role: .destructive) {
                if let action = tableToTruncate {
                    Task {
                        guard let driver = driver(for: action) else { return }
                        do {
                            let statement = SQLBuilder.truncateStatement(
                                table: action.table.name, schema: action.placement.schema,
                                database: action.placement.database, type: connection.type
                            )
                            _ = try await coordinator.track { try await driver.executeWrite([statement]) }
                            await coordinator.refreshTables()
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
            }
        } message: {
            if let action = tableToTruncate {
                Text(ddlConfirmation(String(
                    format: String(localized: "All data in \"%@\" will be permanently deleted."),
                    action.table.name
                )))
            }
        }
        .confirmationDialog(
            String(localized: "Drop Table"),
            isPresented: showDropConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Drop"), role: .destructive) {
                if let action = tableToDrop {
                    Task {
                        guard let driver = driver(for: action) else { return }
                        do {
                            let quoted = SQLBuilder.qualifiedIdentifier(
                                table: action.table.name, schema: action.placement.schema,
                                database: action.placement.database, for: connection.type
                            )
                            _ = try await coordinator.track { try await driver.executeWrite(["DROP TABLE \(quoted)"]) }
                            await coordinator.refreshTables()
                            coordinator.noteCatalogChanged(.tables, reloadedHere: true)
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
            }
        } message: {
            if let action = tableToDrop {
                Text(ddlConfirmation(String(
                    format: String(localized: "The table \"%@\" and all its data will be permanently deleted."),
                    action.table.name
                )))
            }
        }
        .onChange(of: coordinator.tablePlacement) {
            tableToTruncate = nil
            tableToDrop = nil
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @ToolbarContentBuilder
    private var transferMenu: some ToolbarContent {
        if canExport || !importFormats.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canExport {
                        Button {
                            presentDatabaseExport()
                        } label: {
                            Label("Export Database…", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !importFormats.isEmpty {
                        Button {
                            pickFile(for: importFormats)
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    }
                    if canRunSQLFile {
                        Button {
                            pickFile(for: [MobileImportFormats.sql])
                        } label: {
                            Label("Run SQL File…", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Label("More", systemImage: ToolbarSymbols.more())
                }
            }
        }
    }

    private func pickFile(for formats: [any ImportFormatPlugin]) {
        filePickerTypes = ImportPickerTypes.contentTypes(for: formats)
        showFilePicker = true
    }

    private func exportInput(title: String, fileName: String, scope: ExportScopeOption) -> MobileExportInput {
        MobileExportInput(
            title: title,
            fileName: fileName,
            connectionId: connection.id,
            databaseType: connection.type,
            database: exportDatabase,
            schema: exportSchema,
            safeModeLevel: connection.safeModeLevel,
            scopes: [scope]
        )
    }

    private func presentExport(of table: TableInfo) {
        exportItem = MobileExportItem(input: exportInput(
            title: String(localized: "Export Table"),
            fileName: table.name,
            scope: ExportScopeOption(kind: .wholeTable, source: .table(table.name))
        ))
    }

    // Named as the Mac names it: the container the objects sit in, else the database, else the connection.
    private func presentDatabaseExport() {
        let fileName = [exportSchema, exportDatabase, coordinator.displayName]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? String(localized: "Export")
        exportItem = MobileExportItem(input: exportInput(
            title: String(localized: "Export Database"),
            fileName: fileName,
            scope: ExportScopeOption(kind: .database, source: .database)
        ))
    }

    // Another window can switch the shared session between the tap and the confirmation; the table named in the dialog
    // may then sit in another database or schema, so nothing runs.
    private func driver(for action: PendingTableAction) -> (any DatabaseDriver)? {
        guard action.placement == coordinator.tablePlacement, let driver = session?.driver else {
            errorMessage = String(localized: "The connection moved to another database or schema. Choose the table again.")
            showError = true
            return nil
        }
        return driver
    }

    private func ddlConfirmation(_ message: String) -> String {
        OpenTransactionWarning.ddlConfirmation(
            message,
            type: connection.type,
            holdsTransaction: coordinator.transactionHold != nil
        )
    }
}

private struct PendingTableAction {
    let table: TableInfo
    let placement: ConnectionCoordinator.TablePlacement
}

private struct TableRow: View {
    let table: TableInfo

    var body: some View {
        RowItemLabel(title: table.name) {
            Image(systemName: TableKindPresentation.systemImage(for: table.type))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        } trailing: {
            if let rowCount = table.rowCount {
                MetadataBadge(formatRowCount(rowCount))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Opens table data"))
    }

    private var accessibilityLabel: Text {
        let kind = TableKindPresentation.accessibilityKind(for: table.type)
        if let rowCount = table.rowCount {
            return Text("\(kind), \(table.name), \(rowCount) rows")
        }
        return Text("\(kind), \(table.name)")
    }

    private func formatRowCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
