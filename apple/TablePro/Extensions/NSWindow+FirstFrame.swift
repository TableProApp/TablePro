//
//  NSWindow+FirstFrame.swift
//  TablePro
//

import AppKit
import QuartzCore

internal extension NSWindow {
    /// Runs `body` once the display has actually shown a frame of this window.
    ///
    /// `CATransaction.setCompletionBlock` is not that moment: it tracks a transaction's animations,
    /// so for an ordinary non-animated first draw it fires at `commit()` and reports a frame the
    /// WindowServer has not presented yet. `NSView.displayLink(target:selector:)` is the documented
    /// callback for "the display is about to show the next frame", which is the number a person
    /// waiting for the app can feel.
    ///
    /// A window with no screen never drives a display link, so `body` runs immediately there rather
    /// than never. That covers a launch nobody is looking at, which is exactly the case that must
    /// not stall.
    func afterNextFrame(_ body: @escaping @MainActor () -> Void) {
        _ = observeNextFrame(body)
    }

    /// Returns what stops the wait, for a caller that gives up on a frame that may never come.
    private func observeNextFrame(_ body: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        guard screen != nil, let view = contentView else {
            body()
            return {}
        }
        guard #available(macOS 14.0, *) else {
            /// `NSView.displayLink(target:selector:)` and `CADisplayLink` are both macOS 14.
            /// The closest thing 13 has is the transaction's completion plus one hop: the
            /// commit has happened, so the frame is with the WindowServer even though this
            /// cannot wait for it to be presented. It is an approximation, and the caller is
            /// a measurement rather than a correctness gate.
            CATransaction.setCompletionBlock {
                DispatchQueue.main.async { MainActor.assumeIsolated(body) }
            }
            return {}
        }
        let observer = FirstFrameObserver.observe(view, then: body)
        return { observer.cancel() }
    }

    /// Returns once the display has shown this window's next frame, or after `limit`: a hidden or
    /// off-display view drives no display link, so the frame alone could never arrive.
    func nextFrame(limit: Duration = .milliseconds(100)) async {
        let gate = FrameGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            gate.stopObserving = observeNextFrame { gate.open() }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                gate.open()
            }
        }
    }
}

@MainActor
private final class FrameGate {
    var continuation: CheckedContinuation<Void, Never>?
    var stopObserving: (@MainActor () -> Void)?

    // The limit can win, and a display link left registered would hold its observer for good.
    func open() {
        stopObserving?()
        stopObserving = nil
        continuation?.resume()
        continuation = nil
    }
}

@available(macOS 14.0, *)
@MainActor
internal final class FirstFrameObserver: NSObject {
    private static var live: Set<FirstFrameObserver> = []

    static var liveCount: Int { live.count }

    private let body: @MainActor () -> Void
    private var link: CADisplayLink?

    private init(body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    static func observe(_ view: NSView, then body: @escaping @MainActor () -> Void) -> FirstFrameObserver {
        let observer = FirstFrameObserver(body: body)
        let link = view.displayLink(target: observer, selector: #selector(fire))
        observer.link = link
        live.insert(observer)
        link.add(to: .main, forMode: .common)
        return observer
    }

    func cancel() {
        link?.invalidate()
        link = nil
        Self.live.remove(self)
    }

    @objc
    private func fire() {
        guard link != nil else { return }
        cancel()
        body()
    }
}
