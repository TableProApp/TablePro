//
//  WindowOpener.swift
//  TablePro
//
//  Bridges SwiftUI's openWindow environment action to imperative code.
//  Stored on appear by ContentView, WelcomeViewModel, or ConnectionFormView.
//

import os
import SwiftUI

@MainActor
internal final class WindowOpener {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowOpener")
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let shared = WindowOpener()

    private var readyContinuations: [CheckedContinuation<Void, Never>] = []

    /// Set on appear by ContentView, WelcomeViewModel, or ConnectionFormView.
    /// Safe to store — OpenWindowAction is app-scoped, not view-scoped.
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

    /// Suspends until openWindow is set. Returns immediately if already available.
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

    /// Ordered queue of pending payloads — windows requested via openNativeTab
    /// but not yet acknowledged by MainContentView.configureWindow.
    /// Ordered so consumeOldestPendingConnectionId returns the correct entry
    /// when multiple windows open in quick succession (e.g., tab restore).
    internal private(set) var pendingPayloads: [(id: UUID, connectionId: UUID)] = []

    /// Whether any payloads are pending — used for orphan detection in windowDidBecomeKey.
    internal var hasPendingPayloads: Bool { !pendingPayloads.isEmpty }

    /// Opens a new native window tab with the given payload.
    /// Falls back to .openMainWindow notification if openWindow is not yet available
    /// (cold launch from Dock menu before any SwiftUI view has appeared).
    internal func openNativeTab(_ payload: EditorTabPayload) {
        Self.lifecycleLogger.info(
            "[open] t0 WindowOpener.openNativeTab payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) intent=\(String(describing: payload.intent), privacy: .public) skipAutoExecute=\(payload.skipAutoExecute) pendingBefore=\(self.pendingPayloads.count)"
        )
        pendingPayloads.append((id: payload.id, connectionId: payload.connectionId))
        if let openWindow {
            let t0 = Date()
            openWindow(id: "main", value: payload)
            Self.lifecycleLogger.info(
                "[open] WindowOpener.openWindow() returned payloadId=\(payload.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1000))"
            )
        } else {
            Self.logger.info("openWindow not set — falling back to .openMainWindow notification")
            Self.lifecycleLogger.info(
                "[open] fallback to .openMainWindow notification payloadId=\(payload.id, privacy: .public)"
            )
            NotificationCenter.default.post(name: .openMainWindow, object: payload)
        }
    }

    /// Called by MainContentView.configureWindow after the window is fully set up.
    internal func acknowledgePayload(_ id: UUID) {
        let before = pendingPayloads.count
        pendingPayloads.removeAll { $0.id == id }
        Self.lifecycleLogger.info(
            "[open] WindowOpener.acknowledgePayload payloadId=\(id, privacy: .public) pending=\(before)->\(self.pendingPayloads.count)"
        )
    }

    /// Consumes and returns the connectionId for the oldest pending payload.
    /// Removes the entry so subsequent calls return the next payload in order.
    internal func consumeOldestPendingConnectionId() -> UUID? {
        guard !pendingPayloads.isEmpty else { return nil }
        return pendingPayloads.removeFirst().connectionId
    }

    /// Returns the tabbingIdentifier for a connection.
    internal static func tabbingIdentifier(for connectionId: UUID) -> String {
        if AppSettingsManager.shared.tabs.groupAllConnectionTabs {
            return "com.TablePro.main"
        }
        return "com.TablePro.main.\(connectionId.uuidString)"
    }
}
