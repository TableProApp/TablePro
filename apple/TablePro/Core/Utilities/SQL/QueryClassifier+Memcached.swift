//
//  QueryClassifier+Memcached.swift
//  TablePro
//

import Foundation
import TableProMemcachedCore
import TableProSQLGrammar

extension QueryClassifier {
    private static let memcachedReadCommands: Set<String> = ["get", "gets", "version"]
    private static let memcachedReadingStats: Set<String> = ["items", "slabs", "settings", "conns", "sizes", "cachedump"]

    // Read with the driver's own parser, which decodes `\xHH` and `\c` in a quoted word, so `"flush\x5fall"` is the
    // `flush_all` it runs. Only the `stats` forms that read are safe: `stats reset` clears the counters and `stats detail
    // on` changes what the server records. `gat` reads a value and moves its expiry, so it writes. `delete` removes one
    // key, a write as a keyed DELETE is, and `flush_all` empties the cache.
    static func memcachedClassification(_ trimmed: String) -> QueryClassification {
        if trimmed.hasPrefix("MEMCACHED_BROWSE:") || trimmed.hasPrefix("MEMCACHED_REFUSAL:") { return .safe }
        let write = QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        guard let command = try? MemcachedCommandParser.parse(trimmed) else { return memcachedUnparsedClassification(trimmed) }
        switch command {
        case .get, .version, .metadump:
            return .safe
        case .stats(let arguments):
            return memcachedStatsRead(arguments.map { $0.lowercased() }) ? .safe : write
        case .flushAll:
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        case .getAndTouch, .store, .compareAndSwap, .touch, .delete, .increment, .decrement:
            return write
        }
    }

    private static func memcachedStatsRead(_ arguments: [String]) -> Bool {
        guard let subcommand = arguments.first else { return true }
        return memcachedReadingStats.contains(subcommand) || (subcommand == "detail" && arguments.dropFirst().first == "dump")
    }

    // The driver refuses text its parser cannot read; it is tiered by its words all the same.
    private static func memcachedUnparsedClassification(_ trimmed: String) -> QueryClassification {
        let words = trimmed.split(whereSeparator: \.isWhitespace).map {
            $0.lowercased().filter { $0 != "\"" && $0 != "'" }
        }
        guard let command = words.first else { return .safe }
        switch command {
        case "stats":
            return memcachedStatsRead(Array(words.dropFirst()))
                ? .safe
                : QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        case "lru_crawler" where words.dropFirst().first == "metadump":
            return .safe
        default:
            if memcachedReadCommands.contains(command) { return .safe }
            let tier: QueryTier = command == "flush_all" ? .destructive : .write
            return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: false)
        }
    }
}
