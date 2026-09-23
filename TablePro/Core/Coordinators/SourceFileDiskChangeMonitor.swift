//
//  SourceFileDiskChangeMonitor.swift
//  TablePro
//

import Foundation

@MainActor
internal final class SourceFileDiskChangeMonitor {
    typealias StampReader = @Sendable ([URL]) async -> [FileStamp?]

    private struct Probe {
        let tabId: UUID
        let url: URL
        let recordedStamp: FileStamp?
    }

    private weak var tabManager: QueryTabManager?
    private let readStamps: StampReader
    private var inFlight: Task<Void, Never>?
    private var needsAnotherPass = false

    init(tabManager: QueryTabManager, readStamps: @escaping StampReader = SourceFileDiskChangeMonitor.readStampsOffMainActor) {
        self.tabManager = tabManager
        self.readStamps = readStamps
    }

    func refresh() {
        guard inFlight == nil else {
            needsAnotherPass = true
            return
        }
        inFlight = Task { await self.runPasses() }
    }

    func waitUntilIdle() async {
        await inFlight?.value
    }

    func cancel() {
        needsAnotherPass = false
        inFlight?.cancel()
    }

    @concurrent
    nonisolated static func readStampsOffMainActor(_ urls: [URL]) async -> [FileStamp?] {
        urls.map(FileStamp.read)
    }

    private func runPasses() async {
        repeat {
            needsAnotherPass = false
            await runPass()
        } while needsAnotherPass && !Task.isCancelled
        inFlight = nil
    }

    private func runPass() async {
        guard let tabManager else { return }
        let probes = tabManager.tabs.compactMap { tab -> Probe? in
            guard let url = tab.content.sourceFileURL else { return nil }
            return Probe(tabId: tab.id, url: url, recordedStamp: tab.content.savedFileStamp)
        }
        guard !probes.isEmpty else { return }
        let stamps = await readStamps(probes.map(\.url))
        guard !Task.isCancelled else { return }
        for (probe, stamp) in zip(probes, stamps) {
            apply(stamp, to: probe)
        }
    }

    private func apply(_ stamp: FileStamp?, to probe: Probe) {
        guard let tabManager,
              let tab = tabManager.tabs.first(where: { $0.id == probe.tabId }),
              tab.content.sourceFileURL == probe.url,
              tab.content.savedFileStamp == probe.recordedStamp else { return }
        var settled = tab.content
        FileTabBaseline.settle(FileTabBaseline.diskChange(in: settled, current: stamp), in: &settled)
        guard settled.diskChange != tab.content.diskChange
            || settled.dismissedDiskChange != tab.content.dismissedDiskChange else { return }
        tabManager.mutate(tabId: probe.tabId) { mutable in
            mutable.content.diskChange = settled.diskChange
            mutable.content.dismissedDiskChange = settled.dismissedDiskChange
        }
    }
}
