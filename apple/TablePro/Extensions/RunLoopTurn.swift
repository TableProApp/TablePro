//
//  RunLoopTurn.swift
//  TablePro
//

import Foundation

/// Runs a body once, at the end of the main run loop's current turn: after the turn's sources,
/// timers and SwiftUI updates, and after Core Animation commits, just before the loop sleeps.
@MainActor
enum RunLoopTurn {
    static func onEnd(_ body: @escaping @MainActor () -> Void) {
        // Last in the turn, after the CA commit observer, and in every common mode so a scroll or a
        // menu tracking loop does not hold it back.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
