//
//  DatabaseFileClassifier.swift
//  TablePro
//

import Foundation

/// Names the database type that wrote a file, from the file's own bytes rather than its name.
///
/// Reads only as far as the longest declared signature reaches. Anything that is not a regular
/// file, or is empty, or cannot be opened is unidentified rather than an error, and the caller
/// falls back to the extension.
internal enum DatabaseFileClassifier {
    internal static func classify(_ url: URL) -> DatabaseType? {
        classify(url, candidates: PluginMetadataRegistry.shared.allFileSignatures())
    }

    internal static func classify(
        _ url: URL,
        candidates: [String: [DatabaseFileSignature]]
    ) -> DatabaseType? {
        guard url.isFileURL, !candidates.isEmpty else { return nil }
        guard let size = regularFileSize(of: url), size > 0 else { return nil }

        let prefixLength = candidates.values
            .flatMap { $0 }
            .map(\.requiredPrefixLength)
            .max() ?? 0
        guard prefixLength > 0, let prefix = readPrefix(of: url, length: prefixLength) else { return nil }

        /// The longest match wins, and the type id breaks a tie, so the answer never depends on
        /// the order the registry's dictionary happens to iterate in.
        let matches = candidates.flatMap { typeId, signatures in
            signatures.filter { $0.matches(prefix) }.map { (typeId: typeId, weight: $0.totalMarkerLength) }
        }
        let winner = matches.max { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.typeId > rhs.typeId : lhs.weight < rhs.weight
        }
        return winner.map { DatabaseType(rawValue: $0.typeId) }
    }

    /// A FIFO or a device node would block in `open`, so both are refused before anything is opened.
    private static func regularFileSize(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    private static func readPrefix(of url: URL, length: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: length), !head.isEmpty else { return nil }
        return [UInt8](head)
    }
}
