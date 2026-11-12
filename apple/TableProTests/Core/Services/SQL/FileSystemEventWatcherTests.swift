//
//  FileSystemEventWatcherTests.swift
//  TableProTests
//
//  The stream used to hold its watcher unretained, so an event that arrived after the watcher
//  was released read freed memory.
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct FileSystemEventWatcherTests {
    @Test("A change in the folder reaches a live watcher, and none reaches one cancelled or released before delivery")
    func onlyALiveWatcherIsCalled() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemEventWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var silenced = 0
        let cancelled = FileSystemEventWatcher(latency: 0.05)
        cancelled.onChange = { silenced += 1 }
        cancelled.watch([folder.path])
        var released: FileSystemEventWatcher? = FileSystemEventWatcher(latency: 0.05)
        released?.onChange = { silenced += 1 }
        released?.watch([folder.path])

        var reported = 0
        let live = FileSystemEventWatcher(latency: 0.05)
        live.onChange = { reported += 1 }
        live.watch([folder.path])
        defer { live.cancel() }

        try Data("{}".utf8).write(to: folder.appendingPathComponent("theme.json"))
        // Stopped before FSEvents delivers, so this pins that a stopped or released watcher is never called.
        cancelled.cancel()
        released = nil

        try await waitUntil { reported > 0 }
        #expect(silenced == 0)
    }
}
