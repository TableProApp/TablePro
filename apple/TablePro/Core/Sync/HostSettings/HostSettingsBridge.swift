//
//  HostSettingsBridge.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The core's `HostSettings` on the Mac. The settings stores live on the main actor, so each call awaits it; the core
// thread never blocks, and `apply` returns once the stores wrote, since the engine commits the base after it.
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

    func categories() async throws -> [SettingsCategoryArg] {
        let documents = try await onMainActor("read") { [catalog] in try catalog.categories() }
        return try documents.keys.sorted().map { category in
            guard let data = documents[category], let document = String(bytes: data, encoding: .utf8) else {
                throw HostSecretError.Failed(detail: "the settings stores could not read a category")
            }
            return SettingsCategoryArg(category: category, document: document)
        }
    }

    func apply(category: String, document: String?) async throws {
        let data = document.map { Data($0.utf8) }
        try await onMainActor("write") { [catalog] in try catalog.apply(category, document: data) }
    }

    // The detail names no category: a column layout's names a table.
    private func onMainActor<T: Sendable>(
        _ action: String,
        _ body: @escaping @MainActor @Sendable () throws -> T
    ) async throws -> T {
        do {
            return try await MainActor.run(body: body)
        } catch {
            Self.logger.error("Could not \(action, privacy: .public) the synced settings: \(error.publicLogShape, privacy: .public)")
            throw HostSecretError.Failed(detail: "the settings stores could not \(action) a category")
        }
    }
}
