//
//  HostSettingsBridge.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The core's `HostSettings` callback on the Mac. The core calls it on a blocking thread and never under a lock (core ADR
// 0002), and the settings stores live on the main actor, so each call waits for the main thread.
nonisolated final class HostSettingsBridge: HostSettings, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HostSettings")

    private let catalog: HostSettingsCatalog

    init(catalog: HostSettingsCatalog) {
        self.catalog = catalog
    }

    @MainActor
    static func live() -> HostSettingsBridge {
        HostSettingsBridge(catalog: HostSettingsCatalog(stores: AppHostSettingsStores()))
    }

    func categories() throws -> [SettingsCategoryArg] {
        let documents = try onMainActor("read") { [catalog] in try catalog.categories() }
        return try documents.keys.sorted().map { category in
            guard let data = documents[category], let document = String(bytes: data, encoding: .utf8) else {
                throw HostSecretError.Failed(detail: "the settings stores could not read a category")
            }
            return SettingsCategoryArg(category: category, document: document)
        }
    }

    func apply(category: String, document: String?) throws {
        let data = document.map { Data($0.utf8) }
        try onMainActor("write") { [catalog] in try catalog.apply(category, document: data) }
    }

    // The detail names no category: a column layout's names a table.
    private func onMainActor<T: Sendable>(_ action: String, _ body: @MainActor () throws -> T) throws -> T {
        do {
            if Thread.isMainThread {
                return try MainActor.assumeIsolated(body)
            }
            return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
        } catch {
            Self.logger.error("Could not \(action, privacy: .public) the synced settings: \(error.publicLogShape, privacy: .public)")
            throw HostSecretError.Failed(detail: "the settings stores could not \(action) a category")
        }
    }
}
