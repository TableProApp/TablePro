//
//  FileSystemEventWatcher.swift
//  TablePro
//

import CoreServices
import Foundation
import os

internal struct FileSystemEvent: Equatable, Sendable {
    let path: String
    let flags: FSEventStreamEventFlags

    func has(_ flag: Int) -> Bool {
        flags & FSEventStreamEventFlags(flag) != 0
    }
}

@MainActor
internal final class FileSystemEventWatcher {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "FileSystemEventWatcher")

    var onChange: (() -> Void)?

    private let latency: CFTimeInterval
    private let reportsFileEvents: Bool
    private let accepts: @Sendable ([FileSystemEvent]) -> Bool
    private var watchedPaths: Set<String> = []
    private var stream: EventStream?

    // `accepts` runs on the event queue, so a batch it refuses never wakes the main actor.
    init(
        latency: CFTimeInterval = 0.5,
        reportsFileEvents: Bool = false,
        accepts: @escaping @Sendable ([FileSystemEvent]) -> Bool = { _ in true }
    ) {
        self.latency = latency
        self.reportsFileEvents = reportsFileEvents
        self.accepts = accepts
    }

    func watch(_ paths: Set<String>) {
        guard paths != watchedPaths else { return }
        cancel()
        watchedPaths = paths
        guard !paths.isEmpty else { return }

        var flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        if reportsFileEvents {
            flags |= kFSEventStreamCreateFlagFileEvents
        }
        let sink = EventSink(watcher: self, accepts: accepts)
        guard let created = EventStream(
            paths: paths,
            latency: latency,
            flags: FSEventStreamCreateFlags(flags),
            sink: sink
        ) else {
            Self.logger.error("Failed to start a file system event stream")
            return
        }
        stream = created
    }

    func cancel() {
        watchedPaths = []
        // A batch already on its way to the main actor finds no watcher and is dropped.
        stream?.sink.watcher = nil
        stream = nil
    }
}

// Retained by the stream through its context, so a callback never reads freed memory, and it holds
// the watcher weakly, so a released watcher is never called.
@MainActor
private final class EventSink {
    weak var watcher: FileSystemEventWatcher?
    nonisolated let accepts: @Sendable ([FileSystemEvent]) -> Bool

    init(watcher: FileSystemEventWatcher, accepts: @escaping @Sendable ([FileSystemEvent]) -> Bool) {
        self.watcher = watcher
        self.accepts = accepts
    }

    func deliver() {
        watcher?.onChange?()
    }
}

// Stops and releases the stream when it goes away, whether the watcher cancelled it or was released.
private final class EventStream {
    let sink: EventSink
    private let stream: FSEventStreamRef

    init?(paths: Set<String>, latency: CFTimeInterval, flags: FSEventStreamCreateFlags, sink: EventSink) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: EventStream.retainSink,
            release: EventStream.releaseSink,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            EventStream.callback,
            &context,
            Array(paths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.sink = sink
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    nonisolated private static let retainSink: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<EventSink>.fromOpaque(info).retain()
        return info
    }

    nonisolated private static let releaseSink: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<EventSink>.fromOpaque(info).release()
    }

    nonisolated private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
        let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
        let flags = UnsafeBufferPointer(start: eventFlags, count: count)
        let events = zip(paths, flags).map { FileSystemEvent(path: $0, flags: $1) }
        guard sink.accepts(events) else { return }
        Task { @MainActor in
            sink.deliver()
        }
    }
}
