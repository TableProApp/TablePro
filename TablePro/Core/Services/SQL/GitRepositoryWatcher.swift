//
//  GitRepositoryWatcher.swift
//  TablePro
//

import CoreServices
import Foundation
import os

@MainActor
internal final class GitRepositoryWatcher {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "GitRepositoryWatcher")

    var onChange: (() -> Void)?

    private var eventStream: FSEventStreamRef?
    private var watchedPaths: Set<String> = []

    nonisolated private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<GitRepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
        Task { @MainActor in
            watcher.onChange?()
        }
    }

    func watch(_ paths: Set<String>) {
        guard paths != watchedPaths else { return }
        cancel()
        watchedPaths = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            Array(paths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        ) else {
            Self.logger.error("Failed to create the Git repository event stream")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
        FSEventStreamStart(stream)
        eventStream = stream
    }

    func cancel() {
        watchedPaths = []
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }
}
