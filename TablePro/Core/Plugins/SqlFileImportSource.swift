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
    private let dialect: SqlDialect
    private let parser = SQLFileParser()

    private let externalDecompressedURL: URL?
    private let _decompressedURL = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let ownsDecompressedFile: Bool

    init(
        url: URL,
        encoding: String.Encoding,
        dialect: SqlDialect = .generic,
        decompressedURL: URL? = nil,
        ownsDecompressedFile: Bool? = nil
    ) {
        self.url = url
        self.encoding = encoding
        self.dialect = dialect
        self.externalDecompressedURL = decompressedURL
        self.ownsDecompressedFile = ownsDecompressedFile ?? (decompressedURL == nil)
    }

    func fileURL() -> URL {
        url
    }

    func fileSizeBytes() -> Int64 {
        let targetURL = effectiveURL
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: targetURL.path(percentEncoded: false))
            return attrs[.size] as? Int64 ?? 0
        } catch {
            Self.logger.warning("Failed to get file size for \(targetURL.path(percentEncoded: false)): \(error.localizedDescription)")
            return 0
        }
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        let fileURL = try await resolveURL()
        return parser.parseFile(url: fileURL, encoding: encoding)
    }

    func cleanup() {
        guard ownsDecompressedFile else { return }

        let tempURL = _decompressedURL.withLock {
            let url = $0
            $0 = nil
            return url
        }

        for fileURL in [tempURL, externalDecompressedURL].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Self.logger.warning("Failed to clean up temp file: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        guard ownsDecompressedFile else { return }
        let tempURL = _decompressedURL.withLock { $0 }
        for fileURL in [tempURL, externalDecompressedURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private

    private var effectiveURL: URL {
        if let external = externalDecompressedURL {
            return external
        }
        if let decompressed = _decompressedURL.withLock({ $0 }) {
            return decompressed
        }
        return url
    }

    private func resolveURL() async throws -> URL {
        if let external = externalDecompressedURL {
            return external
        }

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
