//
//  DatabaseTreeFilterPopover.swift
//  TablePro
//

import SwiftUI

struct DatabaseTreeFilterPopover: View {
    let connectionId: UUID

    @Binding var enabled: Bool
    @Binding var selectedDatabases: Set<String>

    @Bindable private var treeService = DatabaseTreeMetadataService.shared

    private var selectableDatabases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
            .filter { !$0.isSystemDatabase }
    }

    var body: some View {
        VStack(spacing: 0) {
            Toggle(String(localized: "Only show selected databases"), isOn: $enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            databaseList

            Divider()

            HStack(spacing: 12) {
                Button(String(localized: "Select All")) {
                    selectedDatabases = Set(selectableDatabases.map(\.name))
                }
                .buttonStyle(.borderless)
                .disabled(selectableDatabases.isEmpty)

                Button(String(localized: "Clear")) {
                    selectedDatabases = []
                }
                .buttonStyle(.borderless)
                .disabled(selectedDatabases.isEmpty)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private var databaseList: some View {
        if selectableDatabases.isEmpty {
            ContentUnavailableView(
                String(localized: "No Databases"),
                systemImage: "cylinder",
                description: Text(String(localized: "Connect to load the database list."))
            )
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(selectableDatabases, id: \.name) { db in
                        Toggle(db.name, isOn: databaseBinding(for: db.name))
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 260)
            .disabled(!enabled)
        }
    }

    private func databaseBinding(for database: String) -> Binding<Bool> {
        Binding(
            get: { selectedDatabases.contains(database) },
            set: { isOn in
                if isOn { selectedDatabases.insert(database) }
                else { selectedDatabases.remove(database) }
            }
        )
    }
}
