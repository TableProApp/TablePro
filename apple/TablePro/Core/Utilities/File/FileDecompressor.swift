//
//  FileDecompressor.swift
//  TablePro
//

import Foundation
import TableProGzip

enum DecompressionError: LocalizedError {
    case decompressFailed
    case fileReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .decompressFailed:
            return String(localized: "Failed to decompress .gz file")
        case .fileReadFailed(let message):
            return String(format: String(localized: "Failed to read file: %@"), message)
        }
    }
}

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
