//
//  LastOpenConnectionsStorage.swift
//  TablePro
//
//  Records which connections had open windows at last quit so the
//  "Reopen Last Session" startup behavior can recover after a crash,
//  where AppKit's window-restoration archive is never written.
//

import Foundation
import os

@MainActor
final class LastOpenConnectionsStorage {
    static let shared = LastOpenConnectionsStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LastOpenConnections")

    private let fileURL: URL

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: appSupport.appendingPathComponent("TablePro", isDirectory: true))
    }

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("LastOpenConnections.json")
    }

    func save(connectionIds: [UUID]) {
        guard !connectionIds.isEmpty else {
            clear()
            return
        }
        do {
            let data = try JSONEncoder().encode(connectionIds)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save last open connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load() -> [UUID] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([UUID].self, from: data)
        } catch {
            Self.logger.error("Failed to load last open connections: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
