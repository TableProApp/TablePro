//
//  DataGridView+Prewarm.swift
//  TablePro
//
//  Filling the grid's formatted-text cache ahead of the viewport, and following the viewport as it
//  moves.
//

import AppKit
import Foundation

extension TableViewCoordinator {
    func preWarmDisplayCache(rowCount: Int, from startIndex: Int = 0) {
        let tableRows = tableRowsProvider()
        let displayCount = displayIDs?.count ?? tableRows.count
        let lower = max(0, min(startIndex, displayCount))
        let upper = min(displayCount, lower + max(0, rowCount))
        guard lower < upper else { return }
        for displayIndex in lower..<upper {
            cacheDisplayRow(at: displayIndex, in: tableRows)
        }
    }

    /// The rows the background prewarm is allowed to format, anchored on the viewport.
    ///
    /// A grid mounts on every tab switch, and an unanchored prewarm formatted every loaded row of
    /// every column each time, so arriving at an already-loaded tab cost more the more rows it
    /// held. A miss outside the window is filled by `displayValue(forID:column:rawValue:columnType:)`
    /// while the row draws, so the window bounds the work without bounding what the grid can show.
    func currentPrewarmWindow(displayCount: Int) -> Range<Int> {
        guard let tableView else {
            return DataGridPrewarmWindow.rows(around: 0..<0, displayCount: displayCount)
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        let lower = max(0, visible.location)
        let upper = max(lower, visible.location + visible.length)
        return DataGridPrewarmWindow.rows(around: lower..<upper, displayCount: displayCount)
    }

    /// Fills displayCache off the scroll hot path so viewFor:row: stays a cache hit.
    func startBackgroundPrewarm() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        prewarmTask?.cancel()
        prewarmTask = Task { @MainActor [weak self] in
            await self?.runBackgroundPrewarm()
        }
    }

    /// Pauses prewarm during live scroll; resumes after a debounce so rapid scrolls do not restart it repeatedly.
    func attachScrollObservers(scrollView: NSScrollView) {
        detachScrollObservers()
        let start = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pausePrewarmForScroll()
            }
        }
        let end = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedulePrewarmResume()
            }
        }
        /// The clip view rather than the scroll view's live-scroll pair, because it is the only one
        /// that also reports a programmatic scroll: `scrollRowToVisible`, which is how VoiceOver
        /// reaches a row that is not on screen, and how Find Next and paging move the viewport. The
        /// prewarm window is anchored on the viewport, so those have to re-anchor it too.
        scrollView.contentView.postsBoundsChangedNotifications = true
        let bounds = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.remountAccessibilityCells()
                self?.schedulePrewarmResume()
            }
        }
        scrollObservers = [start, end, bounds]
    }

    func detachScrollObservers() {
        for observer in scrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        scrollObservers.removeAll()
    }

    func pausePrewarmForScroll() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    func schedulePrewarmResume() {
        prewarmResumeTask?.cancel()
        prewarmResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.prewarmResumeDelay)
            guard !Task.isCancelled, let self else { return }
            self.startBackgroundPrewarm()
        }
    }

    func runBackgroundPrewarm() async {
        var nextIndex: Int?
        while !Task.isCancelled {
            let tableRows = tableRowsProvider()
            let displayCount = displayIDs?.count ?? tableRows.count
            let window = currentPrewarmWindow(displayCount: displayCount)
            var index = max(nextIndex ?? window.lowerBound, window.lowerBound)
            guard index < window.upperBound else { return }

            let deadline = ContinuousClock.now.advanced(by: Self.prewarmFrameBudget)
            while index < window.upperBound {
                if Task.isCancelled { return }
                cacheDisplayRow(at: index, in: tableRows)
                index += 1
                if ContinuousClock.now >= deadline { break }
            }
            nextIndex = index
            await Task.yield()
        }
    }
}
