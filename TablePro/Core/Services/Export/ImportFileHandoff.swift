//
//  ImportFileHandoff.swift
//  TablePro
//

import Foundation
import os

internal struct ImportFileHandoff: Equatable, Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportFileHandoff")

    internal let url: URL
    internal let ownsFile: Bool
    /// The name the user knows the file by. A file the app wrote for the handoff has a generated
    /// name of its own, which must never reach the sheet, a proposed table name or history.
    internal let sourceName: String

    internal init(url: URL, ownsFile: Bool, sourceName: String? = nil) {
        self.url = url
        self.ownsFile = ownsFile
        self.sourceName = sourceName ?? url.lastPathComponent
    }

    internal func discard() {
        guard ownsFile else { return }
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.warning("Failed to delete the handed-over import file: \(error.localizedDescription)")
        }
    }
}
