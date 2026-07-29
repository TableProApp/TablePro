//
//  SavedCustomizationsSection.swift
//  TablePro
//

import SwiftUI

struct SavedCustomizationsSection: View {
    @State private var items: [SavedTableCustomization] = []

    var body: some View {
        Group {
            if items.isEmpty {
                Section {
                    Text("No saved customizations yet. Column widths, order, visibility, and per-table filters you set appear here so you can review and reset them.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Saved Customizations")
                }
            } else {
                Section {
                    ForEach(items) { item in
                        row(item)
                    }
                } header: {
                    Text("Saved Customizations")
                } footer: {
                    Text("You edit these inline in the grid and filter bar. Reset a table here to return it to defaults.")
                }

                Section {
                    Button("Reset All Customizations", role: .destructive) {
                        SavedCustomizationsService.resetAll()
                        reload()
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func row(_ item: SavedTableCustomization) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.scope.displayName)
                Text(summary(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Reset") {
                SavedCustomizationsService.reset(item.scope)
                reload()
            }
        }
    }

    private func summary(_ item: SavedTableCustomization) -> String {
        var parts: [String] = []
        if item.hasLayout { parts.append(String(localized: "Columns")) }
        if item.hasFilters { parts.append(String(localized: "Filters")) }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        items = SavedCustomizationsService.all()
    }
}
