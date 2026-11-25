//
//  ForeignSourceScanner.swift
//  TablePro
//

import Foundation

enum ForeignSourceAvailability: Sendable, Equatable {
    case available
    case notFound
    case unreadable(reason: String)
}

struct ForeignSourceSummary: Sendable, Equatable {
    let id: String
    let availability: ForeignSourceAvailability
    let connections: Int
    let picksFile: Bool
}

struct ForeignSourceRow: Sendable, Identifiable {
    let importer: any ForeignAppImporter
    let availability: ForeignSourceAvailability
    let inventory: ForeignAppInventory

    var id: String { importer.id }

    var picksFile: Bool { importer.importFileTypes != nil }

    var summary: ForeignSourceSummary {
        ForeignSourceSummary(id: id, availability: availability, connections: inventory.connections, picksFile: picksFile)
    }
}

// The same rule the core applies; core/crates/foreign-import/tests/fixtures/source_list.json pins both.
enum ForeignSourceRule {
    static func ticked(_ rows: [ForeignSourceSummary]) -> [String] {
        rows.filter { $0.availability == .available && !$0.picksFile && $0.connections > 0 }.map(\.id)
    }

    static func preselected(_ rows: [ForeignSourceSummary]) -> String? {
        var chosen: ForeignSourceSummary?
        for row in rows where row.availability == .available {
            if let current = chosen, current.connections >= row.connections { continue }
            chosen = row
        }
        return chosen?.id
    }
}

enum ForeignSourceScanner {
    // Runs before anyone clicks, so it checks presence only and reads no folder macOS guards with a prompt.
    @concurrent
    nonisolated static func probe(
        _ importers: [any ForeignAppImporter] = ForeignAppImporterRegistry.all
    ) async -> [any ForeignAppImporter] {
        importers.filter { importer in
            importer.importFileTypes == nil && (importer.installedAppURL() != nil || importer.hasDataAtDefaultLocation())
        }
    }

    @concurrent
    nonisolated static func scan(_ importers: [any ForeignAppImporter] = ForeignAppImporterRegistry.all) async -> [ForeignSourceRow] {
        importers.map { row(for: $0) }
    }

    nonisolated static func row(for importer: any ForeignAppImporter) -> ForeignSourceRow {
        if importer.importFileTypes != nil {
            return ForeignSourceRow(importer: importer, availability: .available, inventory: .empty)
        }
        guard importer.isAvailable() else {
            return ForeignSourceRow(importer: importer, availability: .notFound, inventory: .empty)
        }
        do {
            return ForeignSourceRow(importer: importer, availability: .available, inventory: try importer.inventory())
        } catch {
            return ForeignSourceRow(
                importer: importer,
                availability: .unreadable(reason: error.localizedDescription),
                inventory: .empty
            )
        }
    }
}
