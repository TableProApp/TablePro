import SwiftUI
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProTabularIO

// Another connection for a file opened from another app. Picking one closes this sheet and opens that connection
// with the file, the way a link to it opens it.
struct ImportConnectionChoice {
    let connections: [DatabaseConnection]
    let move: (_ connectionId: UUID, _ fileURL: URL) -> Void
}

// The file decides the sheet: rows for CSV, JSON and Excel, statements for SQL.
struct MobileImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinator.self) private var coordinator

    private let fileURL: URL
    private let presetTable: String?
    private let connectionChoice: ImportConnectionChoice?
    private let onFinished: @MainActor () -> Void

    init(
        fileURL: URL,
        presetTable: String? = nil,
        connectionChoice: ImportConnectionChoice? = nil,
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        self.fileURL = fileURL
        self.presetTable = presetTable
        self.connectionChoice = connectionChoice
        self.onFinished = onFinished
    }

    var body: some View {
        if let plugin = MobileImportFormats.plugin(for: fileURL) {
            let controller = ImportRunController(
                sourceURL: fileURL,
                plugin: plugin,
                context: context,
                host: coordinator,
                connectionManager: appState.connectionManager
            )
            if type(of: plugin).formatId == type(of: MobileImportFormats.sql).formatId {
                MobileSQLFileSheet(runner: controller, connectionChoice: connectionChoice) {
                    Task { await coordinator.refreshTables() }
                    onFinished()
                }
            } else {
                MobileRowImportSheet(
                    runner: controller,
                    tables: coordinator.tables,
                    presetTable: presetTable,
                    readTable: tableReader,
                    connectionChoice: connectionChoice,
                    onFinished: onFinished
                )
            }
        } else {
            UnsupportedImportFileView(fileName: fileURL.lastPathComponent)
        }
    }

    private var context: ImportTargetContext {
        ImportTargetContext(
            connectionId: coordinator.connection.id,
            connectionName: coordinator.displayName,
            databaseType: coordinator.connection.type,
            database: coordinator.tableDatabase,
            schema: coordinator.tableQualifier,
            catalogDatabase: coordinator.supportsDatabaseSwitching ? coordinator.activeDatabase : "",
            safeModeLevel: coordinator.connection.safeModeLevel,
            serverVersion: coordinator.session?.driver.serverVersion
        )
    }

    // The catalog connection first, so the read never waits behind the session; the session when there is none.
    private var tableReader: MobileRowImportModel.TableReader {
        let manager = appState.connectionManager
        let coordinator = coordinator
        let context = context
        return { table in
            let schema = context.schema
            let database = context.database
            if let read = try await manager.readCatalog(for: context.connectionId, database: context.catalogDatabase, { driver in
                let columns = try await driver.fetchColumns(table: table, schema: schema, database: database)
                let indexes = try await driver.fetchIndexes(table: table, schema: schema, database: database)
                return (columns: columns, indexes: indexes)
            }) {
                return read
            }
            guard let driver = coordinator.session?.driver else {
                throw MobileTransferRefusal(reason: String(localized: "No active database session."))
            }
            return try await coordinator.track(reading: true) {
                let columns = try await driver.fetchColumns(table: table, schema: schema, database: database)
                let indexes = try await driver.fetchIndexes(table: table, schema: schema, database: database)
                return (columns: columns, indexes: indexes)
            }
        }
    }
}

private struct UnsupportedImportFileView: View {
    let fileName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Cannot Import This File", systemImage: "doc.questionmark")
            } description: {
                Text(verbatim: String(
                    format: String(localized: "%@ is not a CSV, JSON, Excel or SQL file."), fileName
                ))
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// The Stop question, the Safe Mode confirmation and the Read-Only refusal, the same for both sheets.
private struct ImportRunAlerts: ViewModifier {
    let runner: ImportRunController
    let confirmationTitle: String

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Stop Import?"),
                isPresented: Binding(get: { runner.stopQuestion != nil }, set: { if !$0 { runner.answerStop(nil) } }),
                presenting: runner.stopQuestion
            ) { question in
                if question.offersCommit {
                    Button(String(localized: "Stop and Rollback"), role: .destructive) { runner.answerStop(.rollBack) }
                    Button(String(localized: "Stop and Commit")) { runner.answerStop(.commit) }
                } else {
                    Button(String(localized: "Stop Import"), role: .destructive) { runner.answerStop(.rollBack) }
                }
                Button(String(localized: "Continue"), role: .cancel) { runner.answerStop(nil) }
            } message: { question in
                Text(verbatim: question.message)
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { runner.confirmationMessage != nil },
                    set: { if !$0 { runner.cancelConfirmation() } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Import"), role: .destructive) { runner.confirmImport() }
                Button(String(localized: "Cancel"), role: .cancel) { runner.cancelConfirmation() }
            } message: {
                Text(verbatim: runner.confirmationMessage ?? "")
            }
            .alert(
                String(localized: "Import Blocked"),
                isPresented: Binding(get: { runner.blockedMessage != nil }, set: { if !$0 { runner.dismissBlocked() } })
            ) {
                Button(String(localized: "OK"), role: .cancel) { runner.dismissBlocked() }
            } message: {
                Text(verbatim: runner.blockedMessage ?? "")
            }
    }
}

// What every import sheet shows outside configuring: the copy, the run, the summary, the failure.
private struct ImportRunStateView: View {
    let runner: ImportRunController

    var body: some View {
        switch runner.phase {
        case .staging:
            Form {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading the file…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .configuring:
            EmptyView()
        case .running(let progress):
            Form {
                TransferProgressSection(progress: progress)
            }
        case .finished(let summary):
            Form {
                Section {
                    Label {
                        Text(verbatim: summary.headline)
                    } icon: {
                        Image(systemName: summary.succeeded ? "checkmark.circle.fill" : "stop.circle.fill")
                            .foregroundStyle(summary.succeeded ? Color.green : Color.secondary)
                    }
                    ForEach(summary.lines, id: \.self) { line in
                        Text(verbatim: line)
                    }
                }
                if let message = summary.transactionMessage {
                    Section {
                        Text(verbatim: message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Form {
                Section {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Import Failed")
                }
            }
        }
    }
}

@ToolbarContentBuilder
private func importToolbar(
    runner: ImportRunController,
    actionTitle: String,
    canRun: Bool,
    run: @escaping () -> Void,
    dismiss: DismissAction
) -> some ToolbarContent {
    switch runner.phase {
    case .staging, .configuring:
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(actionTitle, action: run)
                .disabled(!canRun)
        }
    case .running:
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Stop"), role: .destructive) { runner.requestStop() }
        }
    case .finished, .failed:
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done")) { dismiss() }
        }
    }
}

private struct ConnectionChoiceSection: View {
    let choice: ImportConnectionChoice
    let currentId: UUID
    let handOff: () -> URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            Picker("Connection", selection: Binding(
                get: { currentId },
                set: { picked in
                    guard picked != currentId, let url = handOff() else { return }
                    choice.move(picked, url)
                    dismiss()
                }
            )) {
                ForEach(choice.connections) { connection in
                    Text(verbatim: connection.name.isEmpty ? connection.host : connection.name).tag(connection.id)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Another connection closes this one and opens that one with the file.")
        }
    }
}

// MARK: - Rows

struct MobileRowImportSheet: View {
    @State private var model: MobileRowImportModel
    @Environment(\.dismiss) private var dismiss
    private let connectionChoice: ImportConnectionChoice?

    init(
        runner: ImportRunController,
        tables: [TableInfo],
        presetTable: String?,
        readTable: @escaping MobileRowImportModel.TableReader,
        connectionChoice: ImportConnectionChoice?,
        onFinished: @escaping @MainActor () -> Void
    ) {
        runner.onFinished = onFinished
        _model = State(initialValue: MobileRowImportModel(
            runner: runner, tables: tables, presetTable: presetTable, readTable: readTable
        ))
        self.connectionChoice = connectionChoice
    }

    private var runner: ImportRunController { model.runner }

    var body: some View {
        NavigationStack {
            Group {
                if runner.isConfiguring {
                    configuration
                } else {
                    ImportRunStateView(runner: runner)
                }
            }
            .navigationTitle(Text("Import Rows"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                importToolbar(
                    runner: runner, actionTitle: String(localized: "Import"), canRun: model.canImport,
                    run: { model.requestImport() }, dismiss: dismiss
                )
            }
        }
        .interactiveDismissDisabled(runner.isRunning)
        .modifier(ImportRunAlerts(runner: runner, confirmationTitle: String(localized: "Import Rows?")))
        .task { await model.start() }
        .onDisappear { runner.close() }
    }

    private var configuration: some View {
        @Bindable var model = model
        return Form {
            if let refusal = runner.refusal {
                Section {
                    Label(refusal, systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("File") {
                    Text(verbatim: runner.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Format") {
                    Text(verbatim: type(of: model.plugin).formatDisplayName)
                }
            }
            if let connectionChoice {
                ConnectionChoiceSection(
                    choice: connectionChoice, currentId: model.context.connectionId, handOff: { runner.handOffFile() }
                )
            }
            destinationSection
            switch model.destination {
            case .existingTable:
                mappingSection
            case .newTable:
                newTableSection
            }
            ImportFormatOptionsSection(plugin: model.plugin)
        }
        .background {
            ImportDetectionSignatureObserver(plugin: model.plugin) {
                Task { await model.read() }
            }
        }
    }

    private var destinationSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Destination", selection: Binding(
                get: { model.destination },
                set: { destination in Task { await model.selectDestination(destination) } }
            )) {
                Text("Existing table").tag(MobileRowImportModel.Destination.existingTable)
                Text("New table").tag(MobileRowImportModel.Destination.newTable)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            switch model.destination {
            case .existingTable:
                Picker("Import into", selection: Binding(
                    get: { model.targetTable },
                    set: { table in Task { await model.selectTable(table) } }
                )) {
                    Text("Select a table…").tag(String?.none)
                    ForEach(model.tables) { table in
                        Text(verbatim: table.name).tag(String?.some(table.name))
                    }
                }
                .pickerStyle(.menu)
                Picker("Import as", selection: Binding(
                    get: { model.writeMode },
                    set: { model.selectWriteMode($0) }
                )) {
                    ForEach(ImportWriteMode.allCases) { mode in
                        Text(verbatim: mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                if model.writeMode.matchesExistingRows {
                    Picker("Match on", selection: $model.matchKey) {
                        ForEach(model.matchKeys) { key in
                            Text(verbatim: key.label).tag(ImportMatchKey?.some(key))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.matchKeys.isEmpty)
                } else {
                    DeleteExistingRowsToggle(plugin: model.plugin)
                }
            case .newTable:
                LabeledContent("New table") {
                    LiteralTextField(String("table_name"), text: $model.newTableName)
                }
            }
        } footer: {
            if let message = model.validationMessage {
                Text(verbatim: message)
                    .foregroundStyle(.red)
            } else if model.destination == .existingTable {
                Text("""
                    Update changes the rows whose key is in the file. Insert or Update also adds the rest, and \
                    Insert, Skip Existing adds only rows whose key is not in the table. Columns not mapped keep \
                    their values.
                    """)
            }
        }
    }

    @ViewBuilder
    private var readState: some View {
        if model.isReading {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading the file…")
                    .foregroundStyle(.secondary)
            }
        } else if let error = model.readError {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "Cannot read this file"), systemImage: "exclamationmark.triangle")
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await model.read() } }
            }
        }
    }

    private var mappingSection: some View {
        let mapping = model.mapping
        return Section {
            if model.isReading || model.readError != nil {
                readState
            } else if model.targetTable == nil {
                Text("Choose a destination table to map fields.")
                    .foregroundStyle(.secondary)
            } else if mapping.rows.isEmpty {
                Text("No fields found in the file.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mapping.rows) { row in
                    Picker(selection: Binding(
                        get: { row.choice.mappedColumn },
                        set: { model.mapping.map(row.field, to: $0) }
                    )) {
                        Text("Do not import").tag(String?.none)
                        ForEach(mapping.columns, id: \.self) { column in
                            Text(verbatim: column).tag(String?.some(column))
                        }
                    } label: {
                        Text(verbatim: row.field)
                    }
                    .pickerStyle(.menu)
                }
            }
        } header: {
            HStack {
                Text("Columns")
                Spacer()
                Menu {
                    Button(String(localized: "Match by Name")) { model.mapping.matchByName() }
                    Button(String(localized: "Match by Position")) { model.mapping.matchByPosition() }
                        .disabled(!model.fieldsFollowFileOrder)
                    Divider()
                    Button(String(localized: "Use Saved Mapping")) { model.mapping.useSavedMapping() }
                        .disabled(!mapping.canUseSavedMapping)
                } label: {
                    Text("Match Columns")
                        .font(.footnote)
                        .textCase(nil)
                }
                .disabled(mapping.rows.isEmpty)
            }
        } footer: {
            if mapping.showsSavedMapping, let table = model.targetTable {
                Text(verbatim: String(format: String(localized: "Restored the mapping saved for %@."), table))
            }
        }
    }

    private var newTableSection: some View {
        let columns = model.newTable.columns
        return Section {
            if model.isReading || model.readError != nil {
                readState
            } else if columns.isEmpty {
                Text("No columns found in the file.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(columns) { column in
                    let settings = column.settings
                    NavigationLink {
                        NewTableColumnEditor(
                            field: column.field.name,
                            settings: newColumnBinding(column.id),
                            typeSuggestions: typeSuggestions
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: settings.include ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.include ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: settings.name.isEmpty ? column.field.name : settings.name)
                                Text(verbatim: settings.isPrimaryKey ? "\(settings.type), PRIMARY KEY" : settings.type)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Columns")
                Spacer()
                if !columns.isEmpty {
                    let includesAll = model.newTable.includesEveryColumn
                    Button(includesAll ? String(localized: "Deselect All") : String(localized: "Select All")) {
                        model.newTable.setAllIncluded(!includesAll)
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        }
    }

    private func newColumnBinding(_ id: String) -> Binding<NewTableColumnSettings> {
        Binding(
            get: {
                model.newTable.columns.first { $0.id == id }?.settings ?? .proposed(name: id, type: "")
            },
            set: { settings in
                guard let index = model.newTable.columns.firstIndex(where: { $0.id == id }) else { return }
                model.newTable.columns[index].settings = settings
            }
        )
    }

    // The type the mapper gives each kind of value, as quick picks beside the free-text type.
    private var typeSuggestions: [String] {
        let context = model.context
        var seen = Set<String>()
        return [PluginImportFieldType.integer, .real, .boolean, .text, .json].compactMap { kind in
            let type = ImportTypeMapper.sqlType(
                for: kind, databaseTypeId: context.databaseType.rawValue, serverVersion: context.serverVersion
            )
            return seen.insert(type.lowercased()).inserted ? type : nil
        }
    }
}

private struct NewTableColumnEditor: View {
    let field: String
    @Binding var settings: NewTableColumnSettings
    let typeSuggestions: [String]

    var body: some View {
        Form {
            Section {
                Toggle("Import this field", isOn: $settings.include)
                LabeledContent("Name") {
                    LiteralTextField("Name", text: $settings.name)
                }
                LabeledContent("Type") {
                    HStack {
                        LiteralTextField("Type", text: $settings.type)
                        Menu {
                            ForEach(typeSuggestions, id: \.self) { type in
                                Button(type) { settings.type = type }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .accessibilityLabel(Text("Suggested Types"))
                    }
                }
            } header: {
                Text(verbatim: field)
            }
            Section {
                Toggle("Allows NULL", isOn: $settings.isNullable)
                Toggle("Primary Key", isOn: $settings.isPrimaryKey)
                LabeledContent("Default") {
                    LiteralTextField("Default", text: $settings.defaultValue)
                }
            } footer: {
                Text("The default is SQL, written after DEFAULT as it is: quote a text value.")
            }
        }
        .navigationTitle(Text(verbatim: settings.name.isEmpty ? field : settings.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - SQL file

struct MobileSQLFileSheet: View {
    @State private var model: MobileSQLFileModel
    @Environment(\.dismiss) private var dismiss
    private let connectionChoice: ImportConnectionChoice?

    init(runner: ImportRunController, connectionChoice: ImportConnectionChoice?, onFinished: @escaping @MainActor () -> Void) {
        runner.onFinished = onFinished
        _model = State(initialValue: MobileSQLFileModel(runner: runner))
        self.connectionChoice = connectionChoice
    }

    private var runner: ImportRunController { model.runner }

    var body: some View {
        NavigationStack {
            Group {
                if runner.isConfiguring {
                    configuration
                } else {
                    ImportRunStateView(runner: runner)
                }
            }
            .navigationTitle(Text("Run SQL File"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                importToolbar(
                    runner: runner, actionTitle: String(localized: "Run"), canRun: model.canRun,
                    run: { model.requestRun() }, dismiss: dismiss
                )
            }
        }
        .interactiveDismissDisabled(runner.isRunning)
        .modifier(ImportRunAlerts(runner: runner, confirmationTitle: String(localized: "Run SQL File?")))
        .task { await model.start() }
        .onDisappear { runner.close() }
    }

    private var configuration: some View {
        Form {
            if let refusal = runner.refusal {
                Section {
                    Label(refusal, systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("File") {
                    Text(verbatim: runner.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let size = runner.file?.fileSize, size > 0 {
                    LabeledContent("Size") {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                LabeledContent("Statements") {
                    if model.isReading {
                        ProgressView()
                    } else if let count = model.statementCount {
                        Text(verbatim: count.formatted())
                            .monospacedDigit()
                    }
                }
            } footer: {
                if let error = model.readError {
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                }
            }
            if let connectionChoice {
                ConnectionChoiceSection(
                    choice: connectionChoice, currentId: runner.context.connectionId, handOff: { runner.handOffFile() }
                )
            }
            Section {
                Picker("Encoding", selection: Binding(
                    get: { model.chosenEncoding },
                    set: { encoding in Task { await model.choose(encoding) } }
                )) {
                    Text(verbatim: String(format: String(localized: "Automatic (%@)"), model.encodingName))
                        .tag(TabularTextEncoding?.none)
                    ForEach(SQLImportFile.encodingChoices, id: \.self) { encoding in
                        Text(verbatim: encoding.displayName).tag(TabularTextEncoding?.some(encoding))
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                if let note = model.overrideNote ?? model.undecodableNote {
                    Text(verbatim: note)
                }
            }
            ImportFormatOptionsSection(plugin: runner.plugin)
        }
    }
}
