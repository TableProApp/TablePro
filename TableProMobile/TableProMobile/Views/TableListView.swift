//
//  TableListView.swift
//  TableProMobile
//

import SwiftUI
import TableProDatabase
import TableProModels

struct TableListView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator

    private var connection: DatabaseConnection { coordinator.connection }
    private var tables: [TableInfo] { coordinator.tables }
    private var session: ConnectionSession? { coordinator.session }

    @State private var searchText = ""
    @State private var tableToTruncate: TableInfo?
    @State private var tableToDrop: TableInfo?
    @State private var errorMessage = ""
    @State private var showError = false

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

    private var tableSections: [(String, [TableInfo])] {
        let tableItems = filteredTables.filter { $0.type == .table || $0.type == .systemTable }
        let viewItems = filteredTables.filter { $0.type == .view || $0.type == .materializedView }

        var sections: [(String, [TableInfo])] = []
        if !tableItems.isEmpty {
            sections.append(("Tables", tableItems))
        }
        if !viewItems.isEmpty {
            sections.append(("Views", viewItems))
        }
        return sections
    }

    var body: some View {
        List {
            ForEach(tableSections, id: \.0) { sectionTitle, items in
                Section {
                    ForEach(items) { table in
                        NavigationLink(value: table) {
                            TableRow(table: table)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = table.name
                            } label: {
                                Label("Copy Name", systemImage: "doc.on.doc")
                            }

                            let isView = table.type == .view || table.type == .materializedView
                            if !isView && !connection.safeModeLevel.blocksWrites {
                                Divider()

                                Button(role: .destructive) {
                                    tableToTruncate = table
                                } label: {
                                    Label("Truncate Table", systemImage: "trash.slash")
                                }

                                Button(role: .destructive) {
                                    tableToDrop = table
                                } label: {
                                    Label("Drop Table", systemImage: "trash")
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
        .searchable(text: $searchText, prompt: "Search tables")
        .toolbar { connectionToolbar }
        .textInputAutocapitalization(.never)
        .refreshable {
            await coordinator.refreshTables()
        }
        .navigationDestination(for: TableInfo.self) { table in
            DataBrowserView(table: table)
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
                if let table = tableToTruncate {
                    Task {
                        do {
                            let quoted = SQLBuilder.quoteIdentifier(table.name, for: connection.type)
                            _ = try await session?.driver.execute(query: "TRUNCATE TABLE \(quoted)")
                            await coordinator.refreshTables()
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
            }
        } message: {
            if let table = tableToTruncate {
                Text("All data in \"\(table.name)\" will be permanently deleted.")
            }
        }
        .confirmationDialog(
            String(localized: "Drop Table"),
            isPresented: showDropConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Drop"), role: .destructive) {
                if let table = tableToDrop {
                    Task {
                        do {
                            let quoted = SQLBuilder.quoteIdentifier(table.name, for: connection.type)
                            _ = try await session?.driver.execute(query: "DROP TABLE \(quoted)")
                            await coordinator.refreshTables()
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }
            }
        } message: {
            if let table = tableToDrop {
                Text("The table \"\(table.name)\" and all its data will be permanently deleted.")
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Connection Toolbar

    @ToolbarContentBuilder
    private var connectionToolbar: some ToolbarContent {
        if connection.safeModeLevel != .off {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: connection.safeModeLevel == .readOnly ? "lock.fill" : "shield.fill")
                    .foregroundStyle(connection.safeModeLevel == .readOnly ? .red : .orange)
                    .font(.caption)
            }
        }
        if coordinator.supportsDatabaseSwitching && coordinator.databases.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(coordinator.databases, id: \.self) { db in
                        Button {
                            Task { await coordinator.switchDatabase(to: db) }
                        } label: {
                            if db == coordinator.activeDatabase {
                                Label(db, systemImage: "checkmark")
                            } else {
                                Text(db)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(coordinator.activeDatabase)
                            .font(.subheadline)
                        if coordinator.isSwitching {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(coordinator.isSwitching)
            }
        }
        if coordinator.supportsSchemas && coordinator.schemas.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(coordinator.schemas, id: \.self) { schema in
                        Button {
                            Task { await coordinator.switchSchema(to: schema) }
                        } label: {
                            if schema == coordinator.activeSchema {
                                Label(schema, systemImage: "checkmark")
                            } else {
                                Text(schema)
                            }
                        }
                    }
                } label: {
                    Label(coordinator.activeSchema, systemImage: "square.3.layers.3d")
                        .font(.subheadline)
                }
                .disabled(coordinator.isSwitching)
            }
        }
    }
}

private struct TableRow: View {
    let table: TableInfo

    var body: some View {
        HStack {
            Image(systemName: table.type == .view || table.type == .materializedView ? "eye" : "tablecells")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(table.name)
                .font(.body)

            Spacer()

            if let rowCount = table.rowCount {
                Text(formatRowCount(rowCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
        }
    }

    private func formatRowCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}
