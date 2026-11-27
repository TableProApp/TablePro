//
//  LoadableExtensionApprovalStore.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

@MainActor
internal protocol LoadableExtensionApproving {
    func unapproved(_ extensions: [LoadableExtension], for connectionId: UUID) -> [LoadableExtension]
    func approve(_ extensions: [LoadableExtension], for connectionId: UUID)
}

// Never synced and keyed per connection: a list that arrived from iCloud, an export, a link or the team library asks before it loads.
@MainActor
internal final class LoadableExtensionApprovalStore: LoadableExtensionApproving {
    internal static let shared = LoadableExtensionApprovalStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LoadableExtensionApprovalStore")
    private static let storageKey = JSONDefaultsKey<[String: Set<LoadableExtension>]>(
        "com.TablePro.loadableExtensionApprovals"
    )

    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    internal func unapproved(_ extensions: [LoadableExtension], for connectionId: UUID) -> [LoadableExtension] {
        let approved = approvals()[connectionId.uuidString] ?? []
        return extensions.filter { !approved.contains(Self.canonical($0)) }
    }

    internal func approve(_ extensions: [LoadableExtension], for connectionId: UUID) {
        guard !extensions.isEmpty else { return }
        var all = approvals()
        all[connectionId.uuidString, default: []].formUnion(extensions.map(Self.canonical))
        save(all)
        Self.logger.info("Approved \(extensions.count, privacy: .public) SQLite extension(s) for a connection")
    }

    internal func revoke(for connectionIds: Set<UUID>) {
        var all = approvals()
        for connectionId in connectionIds {
            all.removeValue(forKey: connectionId.uuidString)
        }
        save(all)
    }

    internal func copyApprovals(from source: UUID, to destination: UUID) {
        guard let approved = approvals()[source.uuidString], !approved.isEmpty else { return }
        var all = approvals()
        all[destination.uuidString, default: []].formUnion(approved)
        save(all)
    }

    private static func canonical(_ item: LoadableExtension) -> LoadableExtension {
        LoadableExtension(path: item.expandedPath, entryPoint: item.entryPoint)
    }

    private func approvals() -> [String: Set<LoadableExtension>] {
        defaults.read(Self.storageKey).value ?? [:]
    }

    private func save(_ approvals: [String: Set<LoadableExtension>]) {
        let kept = approvals.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else {
            defaults.removeValue(for: Self.storageKey)
            return
        }
        try? defaults.write(kept, to: Self.storageKey)
    }
}
