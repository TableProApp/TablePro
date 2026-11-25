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

// A scan nobody clicked must raise no privacy prompt, so it only checks a guarded source for presence.
enum ForeignSourceScanReach: Sendable {
    case everything
    case unguarded
}

struct ForeignSourceRow: Sendable, Identifiable {
    let importer: any ForeignAppImporter
    let availability: ForeignSourceAvailability
    let inventory: ForeignAppInventory
    // False for a guarded source an unguarded scan found without reading it; its inventory stays empty until read.
    var isCounted = true

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
    @concurrent
    nonisolated static func probe(_ importers: [any ForeignAppImporter] = ForeignAppImporterRegistry.all) async -> Set<String> {
        var found: Set<String> = []
        for importer in importers where importer.importFileTypes == nil {
            if importer.installedAppURL() != nil || importer.hasDataAtDefaultLocation() {
                found.insert(importer.id)
            }
        }
        return found
    }

    @concurrent
    nonisolated static func scan(
        _ importers: [any ForeignAppImporter] = ForeignAppImporterRegistry.all,
        reach: ForeignSourceScanReach = .everything
    ) async -> [ForeignSourceRow] {
        importers.map { row(for: $0, reach: reach) }
    }

    @concurrent
    nonisolated static func countedRow(for importer: any ForeignAppImporter) async -> ForeignSourceRow {
        row(for: importer)
    }

    nonisolated static func row(
        for importer: any ForeignAppImporter,
        reach: ForeignSourceScanReach = .everything
    ) -> ForeignSourceRow {
        if importer.importFileTypes != nil {
            return ForeignSourceRow(importer: importer, availability: .available, inventory: .empty)
        }
        if reach == .unguarded, importer.readsGuardedLocations {
            let found = importer.installedAppURL() != nil || importer.hasDataAtDefaultLocation()
            return ForeignSourceRow(
                importer: importer,
                availability: found ? .available : .notFound,
                inventory: .empty,
                isCounted: false
            )
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
