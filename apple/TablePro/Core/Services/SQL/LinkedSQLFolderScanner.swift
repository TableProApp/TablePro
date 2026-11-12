//
//  LinkedSQLFolderScanner.swift
//  TablePro
//

import Foundation
import TableProUtilities

internal struct LinkedSQLFolderScanner: Sendable {
    typealias HeaderLoader = @Sendable (URL) -> FileTextLoader.LoadedText?

    private let index: LinkedSQLIndex
    private let loadHeader: HeaderLoader

    init(
        index: LinkedSQLIndex = .shared,
        loadHeader: @escaping HeaderLoader = { FileTextLoader.loadHeader($0) }
    ) {
        self.index = index
        self.loadHeader = loadHeader
    }

    // Returns whether the folder's rows changed. A file whose size and modification time match its
    // row keeps the row without reading the file.
    @concurrent
    func scan(folderId: UUID, at folderURL: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            return await index.removeFolder(folderId: folderId)
        }
        let stored = await index.storedFiles(folderId: folderId)
        let files = indexedFiles(in: folderURL, stored: stored)
        return await index.synchronize(folderId: folderId, files: files)
    }

    // Returns whether any folder was dropped from the index.
    @concurrent
    func pruneFolders(keeping known: Set<UUID>) async -> Bool {
        var pruned = false
        let stale = await index.allFolderIds().subtracting(known)
        for id in stale {
            if await index.removeFolder(folderId: id) {
                pruned = true
            }
        }
        return pruned
    }

    private func indexedFiles(
        in folderURL: URL,
        stored: [String: LinkedSQLIndex.IndexedFile]
    ) -> [LinkedSQLIndex.IndexedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [LinkedSQLIndex.IndexedFile] = []
        for case let url as URL in enumerator {
            guard SQLFileService.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let relativePath = Self.relativePath(of: url, in: folderURL) else {
                continue
            }
            let mtime = (values.contentModificationDate ?? Date()).timeIntervalSince1970
            let fileSize = Int64(values.fileSize ?? 0)
            if let known = stored[relativePath], known.mtime == mtime, known.fileSize == fileSize {
                files.append(known)
            } else {
                files.append(readFile(at: url, relativePath: relativePath, mtime: mtime, fileSize: fileSize))
            }
        }
        return files
    }

    private func readFile(
        at url: URL,
        relativePath: String,
        mtime: TimeInterval,
        fileSize: Int64
    ) -> LinkedSQLIndex.IndexedFile {
        let header = loadHeader(url)
        let metadata = header.map { SQLFrontmatter.parse($0.content) } ?? SQLFrontmatter.Metadata()
        let baseName = (url.lastPathComponent as NSString).deletingPathExtension
        let name = metadata.name?.trimmingCharacters(in: .whitespaces)
        return LinkedSQLIndex.IndexedFile(
            relativePath: relativePath,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? baseName,
            keyword: metadata.keyword,
            description: metadata.description,
            mtime: mtime,
            fileSize: fileSize,
            encodingName: (header?.encoding ?? .utf8).ianaName
        )
    }

    private static func relativePath(of url: URL, in base: URL) -> String? {
        let urlPath = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard urlPath.hasPrefix(basePath + "/") else { return nil }
        return String(urlPath.dropFirst(basePath.count + 1))
    }
}
