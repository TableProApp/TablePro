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
        guard screen != nil, let view = contentView else {
            body()
            return
        }
        FirstFrameObserver.observe(view, then: body)
    }
}

@MainActor
private final class FirstFrameObserver: NSObject {
    private static var live: Set<FirstFrameObserver> = []

    private let body: @MainActor () -> Void
    private var link: CADisplayLink?

    private init(body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    static func observe(_ view: NSView, then body: @escaping @MainActor () -> Void) {
        let observer = FirstFrameObserver(body: body)
        let link = view.displayLink(target: observer, selector: #selector(fire))
        observer.link = link
        live.insert(observer)
        link.add(to: .main, forMode: .common)
    }

    @objc
    private func fire() {
        link?.invalidate()
        link = nil
        Self.live.remove(self)
        body()
    }
}
