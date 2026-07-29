//
//  PlainFileImportSource.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class PlainFileImportSource: PluginImportSource, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PlainFileImportSource")

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func fileURL() -> URL {
        url
    }

    func fileSizeBytes() -> Int64 {
        let path = url.path(percentEncoded: false)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return attrs[.size] as? Int64 ?? 0
        } catch {
            Self.logger.warning("Failed to get file size for \(path): \(error.localizedDescription)")
            return 0
        }
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        throw PluginImportError.importFailed("This import format does not produce SQL statements")
    }
}
