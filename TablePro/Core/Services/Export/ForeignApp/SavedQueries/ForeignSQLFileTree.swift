//
//  ForeignSQLFileTree.swift
//  TablePro
//

import Foundation
import os

enum ForeignSQLFileTree {
    struct Entry: Sendable, Equatable {
        let url: URL
        let folderPath: [String]
        let fileName: String
        let byteCount: Int
    }

    static let maximumEntryCount = 10_000
    // Leaves room for the app and shared-folder names above a file's own folders.
    static let maximumDepth = 30
    // A tree of folders with few matching files would otherwise be walked in full.
    static let maximumDirectoryCount = 2_000
    private static let inspectedByteCount = 4_096

    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignSQLFileTree")
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
    ]

    static func entries(under root: URL, accepts: (String) -> Bool) -> [Entry] {
        var result: [Entry] = []
        var directoryBudget = maximumDirectoryCount
        walk(root, folderPath: [], accepts: accepts, into: &result, directoryBudget: &directoryBudget)
        if result.count >= maximumEntryCount || directoryBudget <= 0 {
            logger.warning("Stopped listing saved query files at \(result.count) entries")
        }
        return result
    }

    static func content(of entry: Entry, limit: Int) -> ForeignSavedQuery.Content? {
        guard entry.byteCount <= limit else { return .oversized(byteCount: entry.byteCount) }
        guard let handle = try? FileHandle(forReadingFrom: entry.url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), !data.isEmpty else { return nil }
        // The file can grow between listing and reading.
        guard data.count <= limit else { return .oversized(byteCount: max(entry.byteCount, data.count)) }
        return text(from: data).map { .text($0) }
    }

    // Counting must stay cheap, so only a small file is opened to rule out one that is blank.
    static func isCountable(_ entry: Entry) -> Bool {
        guard entry.byteCount > 0 else { return false }
        guard entry.byteCount <= inspectedByteCount else { return true }
        guard let data = try? Data(contentsOf: entry.url) else { return false }
        return text(from: data) != nil
    }

    static func text(from data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func walk(
        _ directory: URL,
        folderPath: [String],
        accepts: (String) -> Bool,
        into result: inout [Entry],
        directoryBudget: inout Int
    ) {
        guard folderPath.count <= maximumDepth, directoryBudget > 0, !Task.isCancelled else { return }
        directoryBudget -= 1
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else { return }

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard result.count < maximumEntryCount else { return }
            let name = child.lastPathComponent
            guard !name.hasPrefix("."),
                  let values = try? child.resourceValues(forKeys: Set(resourceKeys)),
                  values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                walk(child, folderPath: folderPath + [name], accepts: accepts, into: &result, directoryBudget: &directoryBudget)
            } else if values.isRegularFile == true, accepts(name) {
                result.append(Entry(url: child, folderPath: folderPath, fileName: name, byteCount: values.fileSize ?? 0))
            }
        }
    }
}
