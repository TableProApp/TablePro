//
//  CursorTimer.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 1/16/24.
//

import AppKit
import Foundation

class CursorTimer {
    /// # Properties

    /// The timer that publishes the cursor toggle timer.
    private var timer: Timer?
    /// Maps to all cursor views, uses weak memory to not cause a strong reference cycle.
    private var cursors: NSHashTable<CursorView> = .init(options: .weakMemory)
    /// The blink interval asked for by the last reset, nil when stopped or set to never blink.
    private var blinkDuration: TimeInterval?
    /// Tracks whether cursors are hidden or not.
    var shouldHide: Bool = false

    /// Whether a blink timer is scheduled.
    var isRunning: Bool { timer != nil }

    // MARK: - Methods

    /// Resets the cursor blink timer.
    ///
    /// The timer runs only while a drawn cursor is registered. From macOS 14 the caret is an
    /// `NSTextInsertionIndicator`, which blinks itself, so a timer with no cursor would wake the
    /// app twice a second for nothing.
    /// - Parameter newBlinkDuration: The duration to blink, leave as nil to never blink.
    func resetTimer(newBlinkDuration: TimeInterval? = 0.5) {
        invalidateTimer()
        blinkDuration = newBlinkDuration

        guard newBlinkDuration != nil else {
            notifyCursors(shouldHide: true)
            return
        }

        shouldHide = false
        notifyCursors(shouldHide: shouldHide)
        startTimerIfNeeded()
    }

    func stopTimer() {
        shouldHide = true
        notifyCursors(shouldHide: true)
        cursors.removeAllObjects()
        blinkDuration = nil
        invalidateTimer()
    }

    /// Notify all cursors of a new blink state.
    /// - Parameter shouldHide: Whether or not the cursors should be hidden or not.
    private func notifyCursors(shouldHide: Bool) {
        for cursor in cursors.allObjects {
            cursor.blinkTimer(shouldHide)
        }
    }

    /// Register a new cursor view with the timer.
    ///
    /// First responder resets the timer before the layout pass creates the cursor, and that pass
    /// registers it without a reset, so the timer starts here.
    /// - Parameter newCursor: The cursor to blink.
    func register(_ newCursor: CursorView) {
        cursors.add(newCursor)
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil, let blinkDuration, !cursors.allObjects.isEmpty else { return }
        shouldHide = false
        notifyCursors(shouldHide: false)
        timer = Timer.scheduledTimer(withTimeInterval: blinkDuration, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() {
        assertMain()
        // The cursors are held weakly, so a released one leaves the table empty and the timer has nothing to blink.
        guard !cursors.allObjects.isEmpty else {
            invalidateTimer()
            return
        }
        shouldHide.toggle()
        notifyCursors(shouldHide: shouldHide)
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
        timer = nil
        cursors.removeAllObjects()
    }

    private func assertMain() {
#if DEBUG
        assert(Thread.isMainThread, "CursorTimer used from non-main thread")
#endif
    }
}
