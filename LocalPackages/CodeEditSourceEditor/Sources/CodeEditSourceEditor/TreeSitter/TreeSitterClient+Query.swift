//
//  TreeSitterClient+Query.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/27/24.
//

import Foundation
import CodeEditLanguages
import SwiftTreeSitter

// Functions for querying and navigating the tree-sitter node tree. These functions should throw if not able to be
// performed asynchronously as (currently) any editing tasks that would use these must be performed synchronously.

extension TreeSitterClient {
    public struct NodeResult {
        let id: TreeSitterLanguage
        let language: Language
        public let node: Node
    }

    public struct QueryResult {
        let id: TreeSitterLanguage
        let cursor: ResolvingQueryMatchSequence<QueryCursor>
    }

    /// Finds nodes for each language layer at the given location.
    /// - Parameter location: The location to get a node for.
    /// - Returns: All pairs of `Language, Node` where Node is the nearest node in the tree at the given location.
    /// - Throws: A ``TreeSitterClient.Error`` error.
    public func nodesAt(location: Int) throws -> [NodeResult] {
        let range = NSRange(location: location, length: 1)
        return try nodesAt(range: range)
    }

    /// Finds nodes for each language layer at the given location.
    /// - Parameter location: The location to get a node for.
    /// - Returns: All pairs of `Language, Node` where Node is the nearest node in the tree at the given location.
    /// - Throws: A ``TreeSitterClient.Error`` error.
    public func nodesAt(location: Int) async throws -> [NodeResult] {
        let range = NSRange(location: location, length: 1)
        return try await nodesAt(range: range)
    }

    /// Finds nodes in each language layer for the given range.
    /// - Parameter range: The range to get a node for.
    /// - Returns: All pairs of `Language, Node` where Node is the nearest node in the tree in the given range.
    /// - Throws: A ``TreeSitterClient.Error`` error.
    public func nodesAt(range: NSRange) throws -> [NodeResult] {
        try executor.execSync({
            var nodes: [NodeResult] = []
            for layer in self.state?.layers ?? [] {
                if let language = layer.tsLanguage,
                   let node = layer.tree?.rootNode?.descendant(in: range.tsRange.bytes) {
                    nodes.append(NodeResult(id: layer.id, language: language, node: node))
                }
            }
            return nodes
        })
        .throwOrReturn()
    }

    /// Finds nodes in each language layer for the given range.
    /// - Parameter range: The range to get a node for.
    /// - Returns: All pairs of `Language, Node` where Node is the nearest node in the tree in the given range.
    /// - Throws: A ``TreeSitterClient.Error`` error.
    public func nodesAt(range: NSRange) async throws -> [NodeResult] {
        try await executor.exec {
            var nodes: [NodeResult] = []
            for layer in self.state?.layers ?? [] {
                if let language = layer.tsLanguage,
                   let node = layer.tree?.rootNode?.descendant(in: range.tsRange.bytes) {
                    nodes.append(NodeResult(id: layer.id, language: language, node: node))
                }
            }
            return nodes
        }
    }

    /// Perform a query on the tree sitter layer tree.
    /// - Parameters:
    ///   - query: The query to perform.
    ///   - matchingLanguages: A set of languages to limit the query to. Leave empty to not filter out any layers.
    /// - Returns: Any matching nodes from the query.
    public func query(_ query: Query, matchingLanguages: Set<TreeSitterLanguage> = []) throws -> [QueryResult] {
        try executor.execSync({
            guard let readCallback = self.readCallback else { return [] }
            var result: [QueryResult] = []
            for layer in self.state?.layers ?? [] {
                guard matchingLanguages.isEmpty || matchingLanguages.contains(layer.id) else { continue }
                guard let tree = layer.tree else { continue }
                let cursor = query.execute(in: tree)
                let resolvingCursor = cursor.resolve(with: Predicate.Context(textProvider: readCallback))
                result.append(QueryResult(id: layer.id, cursor: resolvingCursor))
            }
            return result
        })
        .throwOrReturn()
    }

    /// Perform a query on the tree sitter layer tree.
    /// - Parameters:
    ///   - query: The query to perform.
    ///   - matchingLanguages: A set of languages to limit the query to. Leave empty to not filter out any layers.
    /// - Returns: Any matching nodes from the query.
    public func query(_ query: Query, matchingLanguages: Set<TreeSitterLanguage> = []) async throws -> [QueryResult] {
        try await executor.exec {
            guard let readCallback = self.readCallback else { return [] }
            var result: [QueryResult] = []
            for layer in self.state?.layers ?? [] {
                guard matchingLanguages.isEmpty || matchingLanguages.contains(layer.id) else { continue }
                guard let tree = layer.tree else { continue }
                let cursor = query.execute(in: tree)
                let resolvingCursor = cursor.resolve(with: Predicate.Context(textProvider: readCallback))
                result.append(QueryResult(id: layer.id, cursor: resolvingCursor))
            }
            return result
        }
    }
}
