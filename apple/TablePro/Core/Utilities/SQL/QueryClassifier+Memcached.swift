//
//  QueryClassifier+Memcached.swift
//  TablePro
//

import Foundation

extension QueryClassifier {
    private static let memcachedReadCommands: Set<String> = ["get", "gets", "version"]
    private static let memcachedDestructiveCommands: Set<String> = ["delete", "flush_all"]
    private static let memcachedReadingStats: Set<String> = ["items", "slabs", "settings", "conns", "sizes", "cachedump"]

    /// Only the `stats` forms that read are safe: `stats reset` clears the counters and `stats detail on` changes
    /// what the server records. `gat` reads a value and moves its expiry, so it writes. The driver strips quotes
    /// before it sends a word, so they are stripped here too.
    static func memcachedClassification(_ trimmed: String) -> QueryClassification {
        if trimmed.hasPrefix("MEMCACHED_BROWSE:") || trimmed.hasPrefix("MEMCACHED_REFUSAL:") { return .safe }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map {
            $0.lowercased().filter { $0 != "\"" && $0 != "'" }
        }
        guard let command = words.first else { return .safe }
        let subcommand = words.dropFirst().first
        switch command {
        case "stats":
            guard let subcommand, !memcachedReadingStats.contains(subcommand) else { return .safe }
            if subcommand == "detail", words.dropFirst(2).first == "dump" { return .safe }
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        case "lru_crawler" where subcommand == "metadump":
            return .safe
        default:
            if memcachedReadCommands.contains(command) { return .safe }
            let tier: QueryTier = memcachedDestructiveCommands.contains(command) ? .destructive : .write
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }
    }
}
