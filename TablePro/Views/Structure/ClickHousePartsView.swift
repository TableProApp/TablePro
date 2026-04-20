//
//  ClickHousePartsView.swift
//  TablePro
//
//  Displays ClickHouse partition/part information from system.parts.
//

import os
import SwiftUI

struct ClickHousePartsView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ClickHousePartsView")

    let tableName: String
    let connectionId: UUID

    @State private var parts: [ClickHousePartInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityHidden(true)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if parts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No parts found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                partsToolbar
                partsTable
            }
        }
        .task { await loadParts() }
    }

    private var partsToolbar: some View {
        HStack(spacing: 8) {
            Button(action: optimizeTable) {
                Label(String(localized: "Optimize"), systemImage: "arrow.triangle.merge")
            }
            .help(String(localized: "Optimize table (merge parts)"))

            Button(action: dropSelectedPartition) {
                Label(String(localized: "Drop Partition"), systemImage: "trash")
            }
            .disabled(selection.count != 1)
            .help(String(localized: "Drop selected partition"))

            Button(action: detachSelectedPartition) {
                Label(String(localized: "Detach Partition"), systemImage: "arrow.down.doc")
            }
            .disabled(selection.count != 1)
            .help(String(localized: "Detach selected partition"))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var partsTable: some View {
        Table(parts, selection: $selection) {
            TableColumn("Partition", value: \.partition)
                .width(min: 80, ideal: 120)
            TableColumn("Name", value: \.name)
                .width(min: 100, ideal: 200)
            TableColumn("Rows") { part in
                Text(formatNumber(part.rows))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            TableColumn("Size") { part in
                Text(formatBytes(part.bytesOnDisk))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            TableColumn("Modified", value: \.modificationTime)
                .width(min: 100, ideal: 160)
            TableColumn("Active") { part in
                Image(systemName: part.active ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(part.active ? Color(nsColor: .systemGreen) : .secondary)
            }
            .width(min: 50, ideal: 60)
        }
    }

    // MARK: - Actions

    private func optimizeTable() {
        Task {
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
            let escapedTable = tableName.replacingOccurrences(of: "`", with: "``")
            let sql = "OPTIMIZE TABLE `\(escapedTable)` FINAL"
            do {
                _ = try await driver.execute(query: sql)
                await loadParts()
            } catch {
                Self.logger.error("Optimize failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func dropSelectedPartition() {
        guard let partitionValue = selectedPartitionValue() else { return }
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Drop Partition?"),
                message: String(
                    format: String(localized: "This will permanently delete all data in partition '%@'."),
                    partitionValue
                ),
                confirmButton: String(localized: "Drop"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }

            guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
            let escapedTable = tableName.replacingOccurrences(of: "`", with: "``")
            let sql = "ALTER TABLE `\(escapedTable)` DROP PARTITION '\(partitionValue.replacingOccurrences(of: "'", with: "''"))'"
            do {
                _ = try await driver.execute(query: sql)
                selection.removeAll()
                await loadParts()
            } catch {
                Self.logger.error("Drop partition failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func detachSelectedPartition() {
        guard let partitionValue = selectedPartitionValue() else { return }
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Detach Partition?"),
                message: String(
                    format: String(localized: "This will detach partition '%@'. Data will be preserved but inaccessible until re-attached."),
                    partitionValue
                ),
                confirmButton: String(localized: "Detach"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }

            guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
            let escapedTable = tableName.replacingOccurrences(of: "`", with: "``")
            let sql = "ALTER TABLE `\(escapedTable)` DETACH PARTITION '\(partitionValue.replacingOccurrences(of: "'", with: "''"))'"
            do {
                _ = try await driver.execute(query: sql)
                selection.removeAll()
                await loadParts()
            } catch {
                Self.logger.error("Detach partition failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func selectedPartitionValue() -> String? {
        guard let selectedId = selection.first,
              let part = parts.first(where: { $0.id == selectedId })
        else { return nil }
        return part.partition
    }

    // MARK: - Data Loading

    private func loadParts() async {
        isLoading = true
        errorMessage = nil

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            errorMessage = String(localized: "Not connected to ClickHouse")
            isLoading = false
            return
        }

        do {
            let escapedTable = tableName.replacingOccurrences(of: "'", with: "''")
            let sql = """
                SELECT partition, name, rows, bytes_on_disk,
                       toString(modification_time) AS mod_time, active
                FROM system.parts
                WHERE database = currentDatabase() AND table = '\(escapedTable)'
                ORDER BY partition, name
                """
            let result = try await driver.execute(query: sql)
            parts = result.rows.compactMap { row -> ClickHousePartInfo? in
                guard let name = row[safe: 1] ?? nil else { return nil }
                let partition = (row[safe: 0] ?? nil) ?? ""
                let rows = (row[safe: 2] ?? nil).flatMap { UInt64($0) } ?? 0
                let bytesOnDisk = (row[safe: 3] ?? nil).flatMap { UInt64($0) } ?? 0
                let modTime = (row[safe: 4] ?? nil) ?? ""
                let active = (row[safe: 5] ?? nil) == "1"
                return ClickHousePartInfo(
                    partition: partition,
                    name: name,
                    rows: rows,
                    bytesOnDisk: bytesOnDisk,
                    modificationTime: modTime,
                    active: active
                )
            }
        } catch {
            Self.logger.error("Failed to load parts: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Formatting

    private func formatNumber(_ number: UInt64) -> String {
        number.formatted(.number.grouping(.automatic))
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case 0..<1_024:
            return "\(bytes) B"
        case 1_024..<1_048_576:
            return String(format: "%.0f KB", Double(bytes) / 1_024)
        case 1_048_576..<1_073_741_824:
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        default:
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
    }
}
