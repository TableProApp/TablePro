//
//  DatabaseTreeFilterPopover.swift
//  TablePro
//

import SwiftUI

struct DatabaseTreeFilterPopover: View {
    let connectionId: UUID

    @Binding var selectedDatabases: Set<String>

    @Bindable private var treeService = DatabaseTreeMetadataService.shared
    @State private var settingsManager = AppSettingsManager.shared
    @State private var searchText: String = ""

    private static let width: CGFloat = 300

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var showsSystemContainers: Bool {
        settingsManager.general.showSystemContainers
    }

    private var selectableDatabases: [DatabaseMetadata] {
        DatabaseTreeVisibility.filterCandidates(databases, showsSystem: showsSystemContainers)
    }

    private var matchingDatabases: [DatabaseMetadata] {
        guard !searchText.isEmpty else { return selectableDatabases }
        return selectableDatabases.filter { SidebarNameFilter.matches(query: searchText, candidate: $0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: Self.width)
    }

    private var searchField: some View {
        NativeSearchField(
            text: $searchText,
            placeholder: String(localized: "Search databases"),
            controlSize: .small
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if selectableDatabases.isEmpty {
            ContentUnavailableView(
                String(localized: "No Databases"),
                systemImage: "cylinder",
                description: Text(String(localized: "Connect to load the database list."))
            )
            .frame(maxWidth: .infinity, minHeight: 160)
        } else if matchingDatabases.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            databaseList
        }
    }

    private var databaseList: some View {
        List {
            ForEach(matchingDatabases, id: \.name) { db in
                Toggle(db.name, isOn: databaseBinding(for: db.name))
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 160, maxHeight: 320)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Show All")) {
                selectedDatabases = []
            }
            .buttonStyle(.borderless)
            .disabled(!isFiltering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isFiltering: Bool {
        DatabaseTreeVisibility.isFiltering(
            selected: selectedDatabases,
            databases: databases,
            showsSystem: showsSystemContainers
        )
    }

    private var countLabel: String {
        guard isFiltering else {
            return String(localized: "Showing all databases")
        }
        let summary = DatabaseTreeVisibility.summary(
            databases: databases,
            selected: selectedDatabases,
            showsSystem: showsSystemContainers
        )
        return String(format: String(localized: "Showing %1$lld of %2$lld"), summary.shown, summary.total)
    }

    private func databaseBinding(for database: String) -> Binding<Bool> {
        Binding(
            get: { selectedDatabases.contains(database) },
            set: { isOn in
                if isOn {
                    selectedDatabases.insert(database)
                } else {
                    selectedDatabases.remove(database)
                }
            }
        )
    }
}
