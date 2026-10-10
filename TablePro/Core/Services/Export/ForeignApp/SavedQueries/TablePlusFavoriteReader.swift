//
//  TablePlusFavoriteReader.swift
//  TablePro
//

import Foundation
import TableProImport

enum TablePlusFavoriteReader {
    struct Root: Sendable, Equatable {
        let url: URL
        let folderPath: [String]
    }

    private static let keywordFileSuffix = ".tag"
    private static let maximumKeywordFileByteCount = 4_096

    static func roots(favoriteRoot: URL, sharedFolders: [URL]) -> [Root] {
        var roots = [Root(url: favoriteRoot, folderPath: [])]
        var seen: Set<String> = [favoriteRoot.standardizedFileURL.path]
        for folder in sharedFolders where seen.insert(folder.standardizedFileURL.path).inserted {
            roots.append(Root(url: folder, folderPath: [folder.lastPathComponent]))
        }
        return roots
    }

    static func sharedFolders(in viewSetting: [String: Any]) -> [URL] {
        guard let entries = viewSetting["Favorites"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let rawPath = (entry["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url
        }
    }

    static func savedQueries(in roots: [Root], limit: Int) throws -> [ForeignSavedQuery] {
        var queries: [ForeignSavedQuery] = []
        for root in roots {
            for entry in entries(under: root.url) {
                try Task.checkCancellation()
                guard let content = ForeignSQLFileTree.content(of: entry, limit: limit) else { continue }
                queries.append(ForeignSavedQuery(
                    name: (entry.fileName as NSString).deletingPathExtension,
                    content: content,
                    keyword: keyword(for: entry),
                    folderPath: root.folderPath + entry.folderPath,
                    sourceConnectionId: nil,
                    isAutoNamed: false
                ))
            }
        }
        return queries
    }

    static func count(in roots: [Root]) -> Int {
        roots.reduce(into: 0) { total, root in
            total += entries(under: root.url).count(where: ForeignSQLFileTree.isCountable)
        }
    }

    // A favorite holds a comma-separated list; a saved query keeps one keyword, and it cannot hold a space.
    static func keyword(for entry: ForeignSQLFileTree.Entry) -> String? {
        let tagURL = entry.url.deletingLastPathComponent()
            .appendingPathComponent(entry.fileName + keywordFileSuffix)
        guard let handle = try? FileHandle(forReadingFrom: tagURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumKeywordFileByteCount),
              let list = String(data: data, encoding: .utf8) else { return nil }
        return list.split(separator: ",")
            .compactMap { SavedQueryKeyword.normalized(String($0)) }
            .first { SavedQueryKeyword.isValid($0) }
    }

    private static func entries(under root: URL) -> [ForeignSQLFileTree.Entry] {
        ForeignSQLFileTree.entries(under: root) { !$0.hasSuffix(keywordFileSuffix) }
    }
}
