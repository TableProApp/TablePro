//
//  TeamLibraryStore.swift
//  TablePro
//
//  Local cache of the pulled team library. Read-only content, small enough to keep as a single JSON
//  file (matching how other small caches persist), guarded by an actor so writes serialize.
//

import Foundation
import os

actor TeamLibraryStore {
    static let shared = TeamLibraryStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryStore")

    private let fileURL: URL
    private var cached: TeamLibraryPullResponse?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TablePro", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("team_library.json")
        }
    }

    func load() -> TeamLibraryPullResponse? {
        if let cached {
            return cached
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        cached = try? JSONDecoder().decode(TeamLibraryPullResponse.self, from: data)
        return cached
    }

    func replace(_ response: TeamLibraryPullResponse) {
        cached = response
        do {
            try JSONEncoder().encode(response).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to cache team library: \(error.localizedDescription)")
        }
    }

    func clear() {
        cached = .empty
        try? FileManager.default.removeItem(at: fileURL)
    }
}
