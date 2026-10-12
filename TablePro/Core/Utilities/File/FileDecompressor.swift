//
//  FileDecompressor.swift
//  TablePro
//
//  Utility for decompressing .gz files using system gunzip command.
//

import Foundation

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

/// Utility for decompressing gzip-compressed files
enum FileDecompressor {
    /// Derive the inner extension from a .gz filename (e.g., "dump.sql.gz" -> "sql")
    private static func innerExtension(for url: URL) -> String {
        let name = url.deletingPathExtension().pathExtension.lowercased()
        return name.isEmpty ? "sql" : name
    }

    /// Case-folded, because the file panel accepts `DUMP.SQL.GZ` as readily as `dump.sql.gz` and a
    /// compressed file that slips past this reaches the statement parser still gzipped.
    static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == ImportFileFormatResolver.compressedFileExtension
    }

    /// Decompress a .gz file to a temporary location
    /// - Parameters:
    ///   - url: URL to the .gz file
    ///   - fileSystemPath: Helper function to get filesystem path for URL
    /// - Returns: URL to the decompressed temporary file, or original URL if not compressed
    /// - Throws: DecompressionError or GzipProcess.GzipError if decompression fails
    static func decompressIfNeeded(
        _ url: URL,
        fileSystemPath: (URL) -> String
    ) async throws -> URL {
        guard isCompressed(url) else { return url }

        let ext = innerExtension(for: url)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)

        do {
            try await GzipProcess.decompress(source: url, destination: tempURL)
        } catch {
            throw DecompressionError.fileReadFailed(error.localizedDescription)
        }

        return tempURL
    }
}
