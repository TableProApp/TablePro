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

/// The SQLite extensions a person has agreed to load on this Mac, per connection.
///
/// An extension is native code that runs inside TablePro, and a connection's list travels through
/// iCloud, exports, `tablepro://` links, linked folders and the team library. So the list alone
/// never authorizes a load: an entry loads only once it was added in the connection form on this
/// Mac or confirmed in the prompt a connect shows. Approval is keyed to the connection as well as
/// the file, so trusting a library for one connection does not quietly approve it for another one
/// that arrives later naming the same path. It is never synced, which is what makes a list that
/// arrived from elsewhere ask first.
@MainActor
internal final class LoadableExtensionApprovalStore: LoadableExtensionApproving {
    internal static let shared = LoadableExtensionApprovalStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LoadableExtensionApprovalStore")
    private static let storageKey = "com.TablePro.loadableExtensionApprovals"

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
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Set<LoadableExtension>].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ approvals: [String: Set<LoadableExtension>]) {
        let kept = approvals.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(kept) else {
            Self.logger.error("Could not encode SQLite extension approvals")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
