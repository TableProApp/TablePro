//
//  RedisKeyTreeViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os

/// The sidebar's Redis key tree for one connection.
///
/// A load owns its outcome only while it is the latest one: selecting another database supersedes
/// it, and a superseded load commits nothing, whatever it came back with. A load that fails with no
/// keys of its database on screen is kept as a failure rather than folded into an empty tree, so a
/// refused `SCAN` reads as the refusal it is. A failed refresh keeps the keys it was refreshing.
@MainActor
internal final class RedisKeyTreeViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RedisKeyTree")
    nonisolated internal static let maxKeys = 50_000

    @Published private(set) var state: MetadataLoadState<RedisKeyTreeContent> = .idle

    private let metadataProvider: any ScopedMetadataProviding
    private var loadTask: Task<Void, Never>?
    private var loadFence = CommitFence<UUID>()
    private var lastRequest: LoadRequest?

    private struct LoadRequest: Sendable {
        let connectionId: UUID
        let database: String
        let separator: String
    }

    init(metadataProvider: any ScopedMetadataProviding = DatabaseManager.shared) {
        self.metadataProvider = metadataProvider
    }

    @discardableResult
    func loadKeys(connectionId: UUID, database: String, separator: String) -> Task<Void, Never> {
        load(LoadRequest(connectionId: connectionId, database: database, separator: separator))
    }

    /// Runs the most recent load again. Nil when nothing has been asked for yet, since there is no
    /// database to reload.
    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard let lastRequest else { return nil }
        return load(lastRequest)
    }

    private func load(_ request: LoadRequest) -> Task<Void, Never> {
        lastRequest = request
        loadTask?.cancel()
        let token = loadFence.supersede(request.connectionId)
        state = state.value?.database == request.database ? state.enteringLoad : .loading

        let provider = metadataProvider
        let task = Task { [weak self] in
            let outcome = await Self.fetch(request, from: provider)
            self?.commit(outcome, of: request, token: token)
        }
        loadTask = task
        return task
    }

    private func commit(_ outcome: MetadataFetchOutcome<RedisKeyTreeContent>, of request: LoadRequest, token: Int) {
        guard loadFence.isCurrent(token, for: request.connectionId) else { return }
        state = state.settled(by: outcome, discardingValue: state.value?.database != request.database)
    }

    private static func fetch(
        _ request: LoadRequest,
        from provider: any ScopedMetadataProviding
    ) async -> MetadataFetchOutcome<RedisKeyTreeContent> {
        let scope = DatabaseScope(connectionId: request.connectionId, database: request.database, schema: nil)
        let limit = maxKeys
        do {
            let result = try await provider.withMetadataDriver(scope: scope) { driver in
                try await driver.execute(query: "KEYTREE LIMIT \(limit)")
            }
            return .fetched(RedisKeyTreeContent(result: result, database: request.database, separator: request.separator))
        } catch {
            if DatabaseCancellationDiagnosis.isCancellation(error) { return .cancelled }
            logger.error("Failed to load Redis keys: \(error.publicLogShape, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Tree Building (Pure Function)

    nonisolated static func buildTree(keys: [(key: String, type: String?)], separator: String) -> [RedisKeyNode] {
        guard !separator.isEmpty else {
            return keys.sorted { $0.key < $1.key }
                .map { .key(name: $0.key, fullKey: $0.key, keyType: $0.type) }
        }

        let root = TrieNode()
        for entry in keys {
            let parts = entry.key.components(separatedBy: separator)
            root.insert(parts: parts, fullKey: entry.key, keyType: entry.type)
        }

        return root.toRedisKeyNodes(parentPrefix: "", separator: separator)
    }
}

// MARK: - Trie for Tree Building

private class TrieNode {
    var children: [String: TrieNode] = [:]
    var leafKeys: [(fullKey: String, keyType: String?)] = []

    func insert(parts: [String], fullKey: String, keyType: String?) {
        guard !parts.isEmpty else {
            leafKeys.append((fullKey: fullKey, keyType: keyType))
            return
        }

        if parts.count == 1 {
            leafKeys.append((fullKey: fullKey, keyType: keyType))
        } else {
            let segment = parts[0]
            let child = children[segment] ?? TrieNode()
            children[segment] = child
            child.insert(parts: Array(parts.dropFirst()), fullKey: fullKey, keyType: keyType)
        }
    }

    func toRedisKeyNodes(parentPrefix: String, separator: String) -> [RedisKeyNode] {
        var nodes: [RedisKeyNode] = []

        let sortedChildren = children.sorted { $0.key < $1.key }
        for (segment, child) in sortedChildren {
            let fullPrefix = parentPrefix.isEmpty ? "\(segment)\(separator)" : "\(parentPrefix)\(segment)\(separator)"
            let childNodes = child.toRedisKeyNodes(parentPrefix: fullPrefix, separator: separator)
            let keyCount = child.countLeafKeys()

            if !childNodes.isEmpty || !child.leafKeys.isEmpty {
                nodes.append(.namespace(
                    name: segment,
                    fullPrefix: fullPrefix,
                    children: childNodes,
                    keyCount: keyCount
                ))
            }
        }

        let sortedLeafs = leafKeys.sorted { $0.fullKey < $1.fullKey }
        for leaf in sortedLeafs {
            let displayName: String
            if parentPrefix.isEmpty {
                displayName = leaf.fullKey
            } else {
                displayName = String(leaf.fullKey.dropFirst(parentPrefix.count))
            }
            nodes.append(.key(name: displayName, fullKey: leaf.fullKey, keyType: leaf.keyType))
        }

        return nodes
    }

    func countLeafKeys() -> Int {
        var count = leafKeys.count
        for child in children.values {
            count += child.countLeafKeys()
        }
        return count
    }
}
