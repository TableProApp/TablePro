//
//  WindowLifecycleMonitor.swift
//  TablePro
//
//  Deterministic NSWindow lifecycle tracker using willCloseNotification.
//  Replaces the fragile SwiftUI onAppear/onDisappear-based NativeTabRegistry
//  with a notification-driven approach that avoids stale entries and timing heuristics.
//

import AppKit
import Foundation

@MainActor
internal final class WindowLifecycleMonitor {
    internal static let shared = WindowLifecycleMonitor()

    private struct Entry {
        let connectionId: UUID
        let window: NSWindow
        var observer: NSObjectProtocol?
        var isPreview: Bool = false
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    deinit {
        for entry in entries.values {
            if let observer = entry.observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        entries.removeAll()
    }

    // MARK: - Registration

    /// Register a window and start observing its willCloseNotification.
    internal func register(window: NSWindow, connectionId: UUID, windowId: UUID, isPreview: Bool = false) {
        // Remove any existing entry for this windowId to avoid duplicate observers
        if let existing = entries[windowId] {
            if let observer = existing.observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closedWindow = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.handleWindowClose(closedWindow)
            }
        }

        entries[windowId] = Entry(
            connectionId: connectionId,
            window: window,
            observer: observer,
            isPreview: isPreview
        )
    }

    /// Remove the UUID mapping for a window.
    internal func unregisterWindow(for windowId: UUID) {
        guard let entry = entries.removeValue(forKey: windowId) else { return }

        if let observer = entry.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Queries

    /// Return all live windows for a connection.
    internal func windows(for connectionId: UUID) -> [NSWindow] {
        entries.values
            .filter { $0.connectionId == connectionId }
            .map(\.window)
    }

    /// Check if other live windows exist for a connection, excluding a specific windowId.
    internal func hasOtherWindows(for connectionId: UUID, excluding windowId: UUID) -> Bool {
        entries.contains { key, value in
            key != windowId && value.connectionId == connectionId
        }
    }

    /// All connection IDs that currently have registered windows.
    internal func allConnectionIds() -> Set<UUID> {
        Set(entries.values.map(\.connectionId))
    }

    /// Find the first visible window for a connection.
    internal func findWindow(for connectionId: UUID) -> NSWindow? {
        entries.values
            .filter { $0.connectionId == connectionId }
            .map(\.window)
            .first { $0.isVisible }
    }

    /// Look up the connectionId for a given windowId.
    internal func connectionId(for windowId: UUID) -> UUID? {
        entries[windowId]?.connectionId
    }

    /// Check if any windows are registered for a connection.
    internal func hasWindows(for connectionId: UUID) -> Bool {
        entries.values.contains { $0.connectionId == connectionId }
    }

    /// Check if a specific window is still registered
    internal func isRegistered(windowId: UUID) -> Bool {
        entries[windowId] != nil
    }

    /// Find the first preview window for a connection.
    internal func previewWindow(for connectionId: UUID) -> (windowId: UUID, window: NSWindow)? {
        entries.first { $0.value.connectionId == connectionId && $0.value.isPreview }
            .map { ($0.key, $0.value.window) }
    }

    /// Look up the NSWindow for a given windowId.
    internal func window(for windowId: UUID) -> NSWindow? {
        entries[windowId]?.window
    }

    /// Update the preview flag for a registered window.
    internal func setPreview(_ isPreview: Bool, for windowId: UUID) {
        entries[windowId]?.isPreview = isPreview
    }

    // MARK: - Private

    private func handleWindowClose(_ closedWindow: NSWindow) {
        guard let (windowId, entry) = entries.first(where: { $0.value.window === closedWindow }) else {
            return
        }

        let closedConnectionId = entry.connectionId

        if let observer = entry.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        entries.removeValue(forKey: windowId)

        let hasRemainingWindows = entries.values.contains { $0.connectionId == closedConnectionId }
        if !hasRemainingWindows {
            Task {
                await DatabaseManager.shared.disconnectSession(closedConnectionId)
            }
        }
    }
}
