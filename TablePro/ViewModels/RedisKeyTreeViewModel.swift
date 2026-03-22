//
//  RedisKeyTreeViewModel.swift
//  TablePro
//

import Foundation
import Observation
import os

@MainActor @Observable
internal final class RedisKeyTreeViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RedisKeyTree")
    private static let maxKeys = 50_000

    var rootNodes: [RedisKeyNode] = []
    var expandedPrefixes: Set<String> = []
    var isLoading = false
    var isTruncated = false
    var separator: String = ":"

    private(set) var allKeys: [(key: String, type: String)] = []

    /// Test-only setter for allKeys
    var allKeysForTesting: [(key: String, type: String)] {
        get { allKeys }
        set { allKeys = newValue }
    }

    func loadKeys(connectionId: UUID, database: String, separator: String) async {
        self.separator = separator
        isLoading = true
        isTruncated = false
        defer { isLoading = false }

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            clear()
            return
        }

        do {
            // Use KEYS command for simplicity — returns all keys matching pattern
            let result = try await driver.execute(query: "KEYS *")

            let keyColumnIndex = result.columns.firstIndex(of: "Key") ?? 0
            let typeColumnIndex = result.columns.firstIndex(of: "Type") ?? 1

            var keys: [(key: String, type: String)] = []
            for row in result.rows {
                guard keyColumnIndex < row.count,
                      let keyName = row[keyColumnIndex] else { continue }
                let keyType = typeColumnIndex < row.count ? (row[typeColumnIndex] ?? "string") : "string"
                keys.append((key: keyName, type: keyType))
                if keys.count >= Self.maxKeys { break }
            }

            isTruncated = keys.count >= Self.maxKeys
            allKeys = keys
            rootNodes = Self.buildTree(keys: keys, separator: separator)
        } catch {
            Self.logger.error("Failed to load Redis keys: \(error.localizedDescription, privacy: .public)")
            clear()
        }
    }

    func clear() {
        rootNodes = []
        allKeys = []
        expandedPrefixes = []
        isTruncated = false
    }

    func displayNodes(searchText: String) -> [RedisKeyNode] {
        guard !searchText.isEmpty else { return rootNodes }

        let filtered = allKeys.filter { $0.key.localizedCaseInsensitiveContains(searchText) }
        if filtered.isEmpty { return [] }

        return Self.buildTree(keys: filtered, separator: separator)
    }

    // MARK: - Tree Building (Pure Function)

    static func buildTree(keys: [(key: String, type: String)], separator: String) -> [RedisKeyNode] {
        guard !separator.isEmpty else {
            return keys.sorted { $0.key < $1.key }
                .map { .key(name: $0.key, fullKey: $0.key, keyType: $0.type) }
        }

        var root = TrieNode()
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
    var leafKeys: [(fullKey: String, keyType: String)] = []

    func insert(parts: [String], fullKey: String, keyType: String) {
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
