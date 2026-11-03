//
//  CloudSQLProxyDownloadTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro
import TableProPluginKit
import TableProTestSupport

@MainActor
struct CloudSQLProxyDownloadTests {
    private let binary = Data("pinned build".utf8)

    private func makeDownload(
        dir: URL,
        expectedSHA256: [String: String]? = nil,
        download: @escaping CloudSQLProxyBinaryManager.Download
    ) -> CloudSQLProxyDownload {
        CloudSQLProxyDownload(binaryManager: CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: expectedSHA256 ?? TestProxyDownload.pins(binary),
            download: download
        ))
    }

    @Test("Progress from the download reaches the shared state, which goes idle once installed")
    func progressReachesSharedState() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = AsyncGate()
        let bytes = binary
        let download = makeDownload(dir: dir) { url, progress in
            await progress(0.25)
            await gate.wait()
            let file = dir.appendingPathComponent("download-\(UUID().uuidString)")
            try bytes.write(to: file)
            return (file, try TestProxyDownload.response(for: url, status: 200))
        }

        download.start()
        try await waitUntil { download.phase == .downloading(fraction: 0.25) }
        await gate.open()
        try await waitUntil { download.phase == .idle }

        #expect(await download.binaryManager.installedBinaryIsCurrent())
    }

    @Test("Callers that arrive during a download share it")
    func concurrentCallersShareOneDownload() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = AsyncGate()
        let record = DownloadRecord()
        let bytes = binary
        let download = makeDownload(dir: dir) { url, _ in
            record.started()
            await gate.wait()
            let file = dir.appendingPathComponent("download-\(UUID().uuidString)")
            try bytes.write(to: file)
            return (file, try TestProxyDownload.response(for: url, status: 200))
        }

        let first = Task { try await download.ensureBinary() }
        try await waitUntil { record.starts == 1 }
        let second = Task { try await download.ensureBinary() }
        try await waitUntil { download.phase.isDownloading }
        await gate.open()

        let installed = download.binaryManager.binaryExecutablePath
        let paths = try await [first.value, second.value]
        #expect(paths == [installed, installed])
        #expect(record.starts == 1)
    }

    @Test("A replacement download stops with its own callers while a cancelled one still unwinds")
    func replacementStopsWithItsOwnCallers() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = AsyncGate()
        let record = DownloadRecord()
        let replacement = DownloadRecord()
        let download = makeDownload(dir: dir) { _, _ in
            record.started()
            guard record.starts > 1 else {
                await gate.wait()
                throw CancellationError()
            }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                replacement.sawCancel()
                throw error
            }
            throw CancellationError()
        }

        let first = Task { try await download.ensureBinary() }
        try await waitUntil { record.starts == 1 }
        download.cancel()
        let second = Task { try await download.ensureBinary() }
        try await waitUntil { record.starts == 2 }
        second.cancel()

        try await waitUntil { replacement.wasCancelled }
        await gate.open()
        _ = try? await first.value
        _ = try? await second.value
    }

    @Test("Cancel stops the download itself and leaves no file and no binary")
    func cancelStopsTheDownload() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = DownloadRecord()
        let download = makeDownload(dir: dir) { _, _ in
            record.started()
            await suspendUntilCancelled()
            record.sawCancel()
            throw URLError(.cancelled)
        }

        let waiter = Task { try await download.ensureBinary() }
        try await waitUntil { record.starts == 1 }
        download.cancel()

        #expect(download.phase == .idle)
        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        try await waitUntil { record.wasCancelled }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("A connect that is cancelled while it alone waits cancels the download")
    func lastWaiterCancelStopsTheDownload() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = DownloadRecord()
        let download = makeDownload(dir: dir) { _, _ in
            record.started()
            await suspendUntilCancelled()
            record.sawCancel()
            throw URLError(.cancelled)
        }

        let connect = Task { try await download.ensureBinary() }
        try await waitUntil { record.starts == 1 }
        connect.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await connect.value
        }
        try await waitUntil { record.wasCancelled && download.phase == .idle }
    }

    @Test("A failed download is published with its reason")
    func failureIsPublished() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let download = makeDownload(dir: dir, download: TestProxyDownload.serving(binary, status: 404, into: dir))

        await #expect(throws: CloudSQLProxyError.downloadFailed(statusCode: 404)) {
            _ = try await download.ensureBinary()
        }

        #expect(download.phase == .failed(CloudSQLProxyError.downloadFailed(statusCode: 404).localizedDescription))
    }

    @Test("A connect that has to download says so, then goes back to waiting for the proxy")
    func connectReportsTheDownloadStage() async throws {
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let download = makeDownload(dir: dir, download: TestProxyDownload.serving(binary, into: dir))
        let stages = StageRecorder()

        _ = try await CloudSQLProxyManager.$connectStageReporter.withValue(stages.report) {
            try await download.ensureBinary()
        }
        #expect(stages.all == [.custom(String(localized: "Downloading Cloud SQL Auth Proxy")), .resolvingTunnel])

        _ = try await CloudSQLProxyManager.$connectStageReporter.withValue(stages.report) {
            try await download.ensureBinary()
        }
        #expect(stages.all.count == 2, "a binary already installed reported a download")
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ConnectionStage] = []

    var report: ConnectionStageReporter {
        { [self] stage in lock.withLock { stages.append(stage) } }
    }

    var all: [ConnectionStage] { lock.withLock { stages } }
}
