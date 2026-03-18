//
//  SqlFileImportSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class SqlFileImportSource: PluginImportSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SqlFileImportSource")

    private let url: URL
    private let encoding: String.Encoding
    private let parser = SQLFileParser()

    private let _decompressedURL = OSAllocatedUnfairLock<URL?>(initialState: nil)

    init(url: URL, encoding: String.Encoding) {
        self.url = url
        self.encoding = encoding
    }

    func fileURL() -> URL {
        url
    }

    func fileSizeBytes() -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            return attrs[.size] as? Int64 ?? 0
        } catch {
            Self.logger.warning("Failed to get file size for \(self.url.path(percentEncoded: false)): \(error.localizedDescription)")
            return 0
        }
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let fileURL = try await decompressIfNeeded()

        let stream = try await parser.parseFile(url: fileURL, encoding: encoding)

        return AsyncThrowingStream { continuation in
            Task {
                for try await item in stream {
                    continuation.yield(item)
                }
                continuation.finish()
            }
        }
    }

    func cleanup() {
        let tempURL = _decompressedURL.withLock {
            let url = $0
            $0 = nil
            return url
        }

        if let tempURL {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                Self.logger.warning("Failed to clean up temp file: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        let tempURL = _decompressedURL.withLock { $0 }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: - Private

    private func decompressIfNeeded() async throws -> URL {
        if let existing = _decompressedURL.withLock({ $0 }) {
            return existing
        }

        let result = try await FileDecompressor.decompressIfNeeded(url) { $0.path() }

        if result != url {
            _decompressedURL.withLock { $0 = result }
        }

        return result
    }
}
