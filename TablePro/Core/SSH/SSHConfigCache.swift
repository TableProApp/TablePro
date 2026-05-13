//
//  SSHConfigCache.swift
//  TablePro
//

import Foundation
import os

actor SSHConfigCache {
    static let shared = SSHConfigCache()

    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHConfigCache")

    private var cachedDocument: SSHConfigDocument?
    private var cachedMtimes: [String: Date] = [:]
    private let configPath: String

    init(configPath: String = SSHConfigParser.defaultConfigPath) {
        self.configPath = configPath
    }

    /// The main config file's mtime is always part of the cache key, even when
    /// it isn't readable (treated as `.distantPast` so a freshly created file
    /// busts the cache). Tracked Include files are checked too. A pre-existing
    /// Include glob that newly matches a file without any main-file edit is
    /// the one residual gap; touching the main file forces a re-parse.
    func current() -> SSHConfigDocument {
        if let cached = cachedDocument, mtimesUnchanged() {
            return cached
        }
        return reload()
    }

    func invalidate() {
        cachedDocument = nil
        cachedMtimes = [:]
    }

    // MARK: - Private

    private func reload() -> SSHConfigDocument {
        let document = SSHConfigParser.parseDocument(path: configPath)
        cachedDocument = document
        var mtimes = Self.collectMtimes(for: document.sourcePaths)
        mtimes[configPath] = Self.mtime(at: configPath) ?? .distantPast
        cachedMtimes = mtimes
        return document
    }

    private func mtimesUnchanged() -> Bool {
        let trackedPaths = Set(cachedMtimes.keys).union([configPath])
        let current = Self.collectMtimes(for: Array(trackedPaths))

        if current.count != cachedMtimes.count { return false }
        for (path, cachedDate) in cachedMtimes where current[path] != cachedDate {
            return false
        }
        return true
    }

    private static func collectMtimes(for paths: [String]) -> [String: Date] {
        var result: [String: Date] = [:]
        for path in paths {
            result[path] = mtime(at: path) ?? .distantPast
        }
        return result
    }

    private static func mtime(at path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
