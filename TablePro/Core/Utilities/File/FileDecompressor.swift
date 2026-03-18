//
//  FileDecompressor.swift
//  TablePro
//
//  Utility for decompressing .gz files using system gunzip command.
//

import Foundation
import os

enum DecompressionError: LocalizedError {
    case decompressFailed
    case fileReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .decompressFailed:
            return String(localized: "Failed to decompress .gz file")
        case .fileReadFailed(let message):
            return String(localized: "Failed to read file: \(message)")
        }
    }
}

/// Utility for decompressing gzip-compressed files
enum FileDecompressor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "FileDecompressor")
    /// Decompress a .gz file to a temporary location
    /// - Parameters:
    ///   - url: URL to the .gz file
    ///   - fileSystemPath: Helper function to get filesystem path for URL
    /// - Returns: URL to the decompressed temporary file, or original URL if not compressed
    /// - Throws: ImportError if decompression fails
    static func decompressIfNeeded(
        _ url: URL,
        fileSystemPath: (URL) -> String
    ) async throws -> URL {
        guard url.pathExtension == "gz" else { return url }

        // Check if gunzip exists
        let gunzipPath = "/usr/bin/gunzip"
        guard FileManager.default.fileExists(atPath: gunzipPath) else {
            throw DecompressionError.fileReadFailed("gunzip not found at \(gunzipPath)")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")

        // Get filesystem path using provided helper
        let filePath = fileSystemPath(url)

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gunzipPath)
            process.arguments = ["-c", filePath]

            let fileManager = FileManager.default
            guard fileManager.createFile(atPath: tempURL.path, contents: nil, attributes: nil) else {
                throw DecompressionError.decompressFailed
            }
            let outputFile = try FileHandle(forWritingTo: tempURL)
            defer {
                do {
                    try outputFile.close()
                } catch {
                    logger.warning("Failed to close decompressed output file handle at \(tempURL.path): \(error)")
                }
            }

            process.standardOutput = outputFile

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                // Try to read error message
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw DecompressionError.fileReadFailed("Failed to decompress .gz file: \(errorMessage)")
            }

            return tempURL
        }.value
    }
}
