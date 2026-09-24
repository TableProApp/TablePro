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
