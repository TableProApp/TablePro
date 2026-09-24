//
//  DataFileWorkingCopy.swift
//  TablePro
//

import Foundation
import os

final class DataFileWorkingCopy: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataFiles")

    let directory: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProDataFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Could not remove a data file working copy: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    func file(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    @concurrent
    func snapshot(of url: URL, kind: DataFileKind) async throws -> URL {
        if kind.isCompressed {
            let destination = file(named: "content-\(UUID().uuidString).\(kind.contentExtension)")
            try await GzipProcess.decompress(source: url, destination: destination)
            return destination
        }
        let values = try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey, .volumeIsLocalKey])
        let supportsCloning = values?.volumeSupportsFileCloning ?? false
        let isLocal = values?.volumeIsLocal ?? false
        guard supportsCloning || !isLocal else { return url }
        let destination = file(named: "content-\(UUID().uuidString).\(kind.contentExtension)")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
