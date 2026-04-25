//
//  ConnectionImportPreviewList.swift
//  TablePro
//

import SwiftUI

struct ConnectionImportPreviewList: View {
    let items: [ImportItem]
    @Binding var selectedIds: Set<UUID>
    @Binding var duplicateResolutions: [UUID: ImportResolution]

    var body: some View {
        List {
            ForEach(items) { item in
                importItemRow(item)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func importItemRow(_ item: ImportItem) -> some View {
        let isSelected = selectedIds.contains(item.id)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    if newValue {
                        selectedIds.insert(item.id)
                    } else {
                        selectedIds.remove(item.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            DatabaseType(rawValue: item.connection.type).iconImage
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.connection.name)
                        .font(.body)
                        .lineLimit(1)
                    if case .duplicate = item.status {
                        Text(String(localized: "duplicate"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: .quaternaryLabelColor))
                            )
                    }
                }
                HStack(spacing: 0) {
                    Text("\(item.connection.host):\(item.connection.port)")
                    warningText(for: item.status)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if case .duplicate = item.status, isSelected {
                Picker("", selection: Binding(
                    get: { duplicateResolutions[item.id] ?? .importAsCopy },
                    set: { duplicateResolutions[item.id] = $0 }
                )) {
                    Text(String(localized: "As Copy")).tag(ImportResolution.importAsCopy)
                    if case .duplicate(let existing) = item.status {
                        Text(String(localized: "Replace")).tag(ImportResolution.replace(existingId: existing.id))
                    }
                    Text(String(localized: "Skip")).tag(ImportResolution.skip)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 110)
                .labelsHidden()
            } else {
                statusIcon(for: item.status)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(for status: ImportItemStatus) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .warnings:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color(nsColor: .systemYellow))
        case .duplicate:
            EmptyView()
        }
    }

    @ViewBuilder
    private func warningText(for status: ImportItemStatus) -> some View {
        if case .warnings(let messages) = status, let first = messages.first {
            Text(" — \(first)")
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
    }
}
