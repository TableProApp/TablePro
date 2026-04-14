//
//  DatabaseFileWatcher.swift
//  TablePro
//
//  Watches database files for external modifications using DispatchSource.
//  After each detected change, the watcher re-opens the file descriptor to
//  handle SQLite journaling operations that can invalidate the original fd.
//

import Foundation
import os

@MainActor
final class DatabaseFileWatcher {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DatabaseFileWatcher")

    private var activeSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var watchedPaths: [UUID: String] = [:]
    private var callbacks: [UUID: @MainActor () -> Void] = [:]

    private let debounceInterval: Duration = .milliseconds(500)

    // MARK: - Public API

    func watch(filePath: String, connectionId: UUID, onChange: @escaping @MainActor () -> Void) {
        stopWatching(connectionId: connectionId)

        let expandedPath = (filePath as NSString).expandingTildeInPath
        watchedPaths[connectionId] = expandedPath
        callbacks[connectionId] = onChange

        startSource(connectionId: connectionId)
    }

    func stopWatching(connectionId: UUID) {
        debounceTasks[connectionId]?.cancel()
        debounceTasks.removeValue(forKey: connectionId)

        if let source = activeSources.removeValue(forKey: connectionId) {
            source.cancel()
        }
        watchedPaths.removeValue(forKey: connectionId)
        callbacks.removeValue(forKey: connectionId)
    }

    func stopAll() {
        for id in activeSources.keys {
            stopWatching(connectionId: id)
        }
    }

    // MARK: - Private

    private func startSource(connectionId: UUID) {
        // Cancel any existing source
        if let existing = activeSources.removeValue(forKey: connectionId) {
            existing.cancel()
        }

        guard let path = watchedPaths[connectionId] else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.warning("Cannot open database file for watching: \(path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .revoke],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleEvent(connectionId: connectionId)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        activeSources[connectionId] = source
        source.resume()
    }

    private func handleEvent(connectionId: UUID) {
        // Re-create the watcher to get a fresh file descriptor.
        // SQLite journaling (rename + recreate) can invalidate the old fd.
        startSource(connectionId: connectionId)

        // Debounced refresh
        debounceTasks[connectionId]?.cancel()
        debounceTasks[connectionId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.callbacks[connectionId]?()
        }
    }
}
