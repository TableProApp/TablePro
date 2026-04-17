//
//  WindowOpener.swift
//  TablePro
//
//  Bridges SwiftUI's `OpenWindowAction` to imperative call sites for the
//  remaining SwiftUI scenes (Welcome, Connection Form, Settings). The main
//  editor windows no longer use this — they go through `WindowManager.openTab`
//  directly.
//

import os
import SwiftUI

@MainActor
internal final class WindowOpener {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowOpener")

    internal static let shared = WindowOpener()

    private var readyContinuations: [CheckedContinuation<Void, Never>] = []

    /// Set on appear by `OpenWindowHandler` (TableProApp). Used to open the
    /// welcome window, connection form, and settings from imperative code.
    /// Safe to store — `OpenWindowAction` is app-scoped, not view-scoped.
    internal var openWindow: OpenWindowAction? {
        didSet {
            if openWindow != nil {
                for continuation in readyContinuations {
                    continuation.resume()
                }
                readyContinuations.removeAll()
            }
        }
    }

    /// Suspends until `openWindow` is set. Returns immediately if available.
    /// Used by Dock-menu / URL-scheme cold-launch paths that fire before any
    /// SwiftUI view has appeared.
    internal func waitUntilReady() async {
        if openWindow != nil { return }
        await withCheckedContinuation { continuation in
            if openWindow != nil {
                continuation.resume()
            } else {
                readyContinuations.append(continuation)
            }
        }
    }
}
