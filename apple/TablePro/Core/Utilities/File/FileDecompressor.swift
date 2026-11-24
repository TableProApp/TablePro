//
//  FileDecompressor.swift
//  TablePro
//

import Foundation
import TableProGzip

enum FileDecompressor {
    private static func innerExtension(for url: URL) -> String {
        let name = url.deletingPathExtension().pathExtension.lowercased()
        return name.isEmpty ? "sql" : name
    }

    // The file panel accepts DUMP.SQL.GZ too, and a missed one reaches the statement parser still gzipped.
    static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == ImportFileFormatResolver.compressedFileExtension
    }

    static func decompressIfNeeded(_ url: URL) async throws -> URL {
        guard isCompressed(url) else { return url }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + innerExtension(for: url))
        try await GzipFile.decompress(source: url, destination: tempURL)
        return tempURL
    }
}
