//
//  QueryClassifier+Memcached.swift
//  TablePro
//

import Foundation

extension QueryClassifier {
    private static let memcachedReadCommands: Set<String> = ["get", "gets", "version"]
    private static let memcachedDestructiveCommands: Set<String> = ["delete", "flush_all"]

    /// `stats reset` clears the counters and `stats detail on` changes what the server records; every other
    /// `stats` form only reads, as does `lru_crawler metadump`. `gat` reads a value and moves its expiry, so it writes.
    static func memcachedClassification(_ trimmed: String) -> QueryClassification {
        if trimmed.hasPrefix("MEMCACHED_BROWSE:") || trimmed.hasPrefix("MEMCACHED_REFUSAL:") { return .safe }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let command = words.first else { return .safe }
        if command == "stats" {
            let changesServer = words.dropFirst().first.map { $0 == "reset" || $0 == "detail" } ?? false
            return changesServer ? QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false) : .safe
        }
        if command == "lru_crawler", words.dropFirst().first == "metadump" { return .safe }
        if memcachedReadCommands.contains(command) { return .safe }
        let tier: QueryTier = memcachedDestructiveCommands.contains(command) ? .destructive : .write
        return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
    }
}
