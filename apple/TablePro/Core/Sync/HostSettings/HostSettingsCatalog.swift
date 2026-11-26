//
//  HostSettingsCatalog.swift
//  TablePro
//

import Foundation
import os

// The Mac's side of the `macos_settings` kind (core ADR 0054, Adapters): every category this Mac holds, as one JSON
// document each, and the documents a pull settled. The engine merges; this only reads and writes the stores.
@MainActor
final class HostSettingsCatalog {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HostSettings")

    // A record is at most 1 MiB (core ADR 0051, Limits). What a server can make this Mac keep is bounded too: past it a
    // pull fails rather than this Mac dropping a category, which would read as deleted.
    static let maximumDocumentBytes = 1 << 20
    static let maximumKeptCategories = 512
    static let maximumKeptBytes = 4 << 20

    private let stores: any HostSettingsStores
    private let keptFile: JSONFileStore<HostSettingsKept>
    private let build: String
    private var kept: HostSettingsKept?

    init(
        stores: any HostSettingsStores,
        keptFile: JSONFileStore<HostSettingsKept> = HostSettingsCatalog.defaultKeptFile,
        build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    ) {
        self.stores = stores
        self.keptFile = keptFile
        self.build = build
    }

    nonisolated static var defaultKeptFile: JSONFileStore<HostSettingsKept> {
        JSONFileStore(url: AppStorageEnvironment.shared.supportDirectory
            .appendingPathComponent("SyncSettingsKept.json", isDirectory: false))
    }

    func categories() throws -> [String: Data] {
        var kept = try loadKept()
        let before = kept
        try tryKeptWithThisBuild(&kept)
        var reported: [String: Data] = [:]
        let local = try stores.documents()
        for (category, data) in local {
            if let document = try kept.report(category, local: try SettingsJSON.parse(data)) {
                reported[category] = try SettingsJSON.canonical(document)
            }
        }
        for category in kept.categories where local[category] == nil {
            if let document = try kept.report(category, local: nil) {
                reported[category] = try SettingsJSON.canonical(document)
            }
        }
        try save(kept, ifChangedFrom: before)
        return reported
    }

    // Nil removes the category, which the engine asks only for a theme or a column layout.
    func apply(_ category: String, document: Data?) throws {
        var kept = try loadKept()
        let before = kept
        guard let document else {
            try stores.remove(category)
            kept.forget(category)
            try save(kept, ifChangedFrom: before)
            return
        }
        guard document.count <= Self.maximumDocumentBytes,
              kept.entries[category] != nil || kept.entries.count < Self.maximumKeptCategories,
              kept.byteCount + 2 * document.count <= Self.maximumKeptBytes
        else { throw HostSettingsStoreError.overBudget(category) }
        let sent = try SettingsJSON.parse(document)
        let kind = HostSettingsCategoryKind(category)
        let written = try stores.write(document, for: category)
        let held = try stores.document(for: category).map(SettingsJSON.parse)
        try kept.record(category, shape: written == .written ? kind.keptShape : .document, sent: sent, held: held)
        if !kept.entries.isEmpty, before.entries.isEmpty {
            kept.triedBuild = build
        }
        try save(kept, ifChangedFrom: before)
    }

    // A newer build may read what an older one kept, so each build offers the kept values to its stores once. Only
    // what the store still holds as it was gets the kept value, so no edit made here is written over.
    private func tryKeptWithThisBuild(_ kept: inout HostSettingsKept) throws {
        guard !kept.entries.isEmpty, kept.triedBuild != build else { return }
        for category in kept.categories {
            let local = try stores.document(for: category).map(SettingsJSON.parse)
            guard let document = try kept.report(category, local: local) else { continue }
            let kind = HostSettingsCategoryKind(category)
            let written = try stores.write(try SettingsJSON.canonical(document), for: category)
            let held = try stores.document(for: category).map(SettingsJSON.parse)
            try kept.record(category, shape: written == .written ? kind.keptShape : .document, sent: document, held: held)
        }
        kept.triedBuild = build
    }

    // An unreadable file fails the pass: read as empty, a category only it holds would go up as deleted.
    private func loadKept() throws -> HostSettingsKept {
        if let kept {
            return kept
        }
        let loaded: HostSettingsKept
        switch keptFile.read() {
        case .value(let value):
            loaded = value
        case .missing:
            loaded = HostSettingsKept()
        case .unreadable(let error):
            throw error
        }
        kept = loaded
        return loaded
    }

    private func save(_ next: HostSettingsKept, ifChangedFrom before: HostSettingsKept) throws {
        guard next != before else { return }
        if next.entries.isEmpty {
            try keptFile.remove()
        } else {
            try keptFile.write(next)
        }
        kept = next
    }
}
