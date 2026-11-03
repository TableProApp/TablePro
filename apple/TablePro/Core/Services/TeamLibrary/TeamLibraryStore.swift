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
    // Bumped without waiting on the actor, so a write already queued when the license changes or clears is refused.
    private let writeGeneration = OSAllocatedUnfairLock(initialState: 0)

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = AppStorageEnvironment.shared.applicationSupportRoot
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
        cached = (try? JSONDecoder().decode(TeamLibraryPullResponse.self, from: data))?.sanitized()
        return cached
    }

    nonisolated var generation: Int {
        writeGeneration.withLock { $0 }
    }

    nonisolated func invalidatePendingWrites() {
        writeGeneration.withLock { $0 += 1 }
    }

    // Nil when a clear or license change came after the pull this response answers.
    func replace(_ response: TeamLibraryPullResponse, ifGeneration expected: Int) -> TeamLibraryPullResponse? {
        guard generation == expected else { return nil }
        let sanitized = response.sanitized()
        cached = sanitized
        do {
            try JSONEncoder().encode(sanitized).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to cache team library: \(error.publicLogShape, privacy: .public)")
        }
        return sanitized
    }

    func clear() {
        cached = .empty
        try? FileManager.default.removeItem(at: fileURL)
    }
}
