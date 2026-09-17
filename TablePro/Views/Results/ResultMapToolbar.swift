//
//  ResultMapToolbar.swift
//  TablePro
//

import SwiftUI

struct ResultMapToolbar: View {
    @Binding var configuration: ResultMapConfiguration
    let columns: [SpatialColumn]
    let resolved: SpatialColumn?
    let status: String
    let canFit: Bool
    let onFit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if columns.count > 1 {
                Picker(String(localized: "Geometry Column"), selection: geometryBinding) {
                    ForEach(columns) { column in
                        Text(column.displayName).tag(column.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("result-map-column-picker")
            }

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(status)

            Spacer()

            Button {
                onFit()
            } label: {
                Label(String(localized: "Fit to Result"), systemImage: "arrow.down.left.and.arrow.up.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!canFit)
            .accessibilityIdentifier("result-map-fit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The picker binds to a non-optional id so a segment is always selected, while the stored
    /// configuration keeps nil meaning "whichever column the result offers first".
    private var geometryBinding: Binding<SpatialColumnID?> {
        Binding(
            get: { resolved?.id ?? configuration.geometryColumn },
            set: { configuration.geometryColumn = $0 }
        )
    }
}
