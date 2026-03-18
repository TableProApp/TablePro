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

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if parts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No parts found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                partsTable
            }
        }
        .task { await loadParts() }
    }

    private var partsTable: some View {
        Table(parts) {
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
                    .foregroundStyle(part.active ? .green : .secondary)
            }
            .width(min: 50, ideal: 60)
        }
    }

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

    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
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
