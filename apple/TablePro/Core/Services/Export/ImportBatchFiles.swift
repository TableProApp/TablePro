//
//  ImportBatchFiles.swift
//  TablePro
//

import Foundation

/// The files a choice of several files or folders imports as rows, each with the format its extension names.
///
/// A folder gives the visible files directly inside it, not those of its subfolders, in Finder's order. A file no
/// row format reads, a SQL dump among them, is left out by name rather than dropped silently: a dump runs its own
/// statements and is imported on its own.
internal enum ImportBatchFiles {
    internal struct File: Equatable, Sendable {
        internal let url: URL
        internal let formatId: String
    }

    internal struct Resolution: Equatable, Sendable {
        internal var files: [File] = []
        internal var leftOut: [URL] = []
    }

    internal static func resolve(
        _ urls: [URL],
        among options: [ImportFormatOption],
        readsRows: (String) -> Bool
    ) -> Resolution {
        var resolution = Resolution()
        var seen = Set<String>()
        for url in urls {
            let candidates = isDirectory(url) ? contents(of: url) : [url]
            for candidate in candidates {
                let key = candidate.standardizedFileURL.path(percentEncoded: false)
                guard seen.insert(key).inserted else { continue }
                if case .format(let formatId) = ImportFileFormatResolver.match(candidate, among: options),
                   readsRows(formatId) {
                    resolution.files.append(File(url: candidate, formatId: formatId))
                } else {
                    resolution.leftOut.append(candidate)
                }
            }
        }
        return resolution
    }

    internal static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func contents(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isRegularFile == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
