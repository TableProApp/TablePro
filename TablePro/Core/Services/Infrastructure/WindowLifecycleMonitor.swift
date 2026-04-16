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
import OSLog

@MainActor
internal final class WindowLifecycleMonitor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowLifecycleMonitor")
    internal static let shared = WindowLifecycleMonitor()

    private struct Entry {
        let connectionId: UUID
        weak var window: NSWindow?
        var observer: NSObjectProtocol?
        var isPreview: Bool = false
    }

    private var entries: [UUID: Entry] = [:]
    private var sourceFileWindows: [URL: UUID] = [:]

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
            if existing.window !== window {
                Self.logger.warning("Re-registering windowId \(windowId) with a different NSWindow")
            }
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
        unregisterSourceFiles(for: windowId)
        guard let entry = entries.removeValue(forKey: windowId) else { return }

        if let observer = entry.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Queries

    /// Return all live windows for a connection.
    internal func windows(for connectionId: UUID) -> [NSWindow] {
        purgeStaleEntries()
        return entries.values
            .filter { $0.connectionId == connectionId }
            .compactMap(\.window)
    }

    /// Check if other live windows exist for a connection, excluding a specific windowId.
    internal func hasOtherWindows(for connectionId: UUID, excluding windowId: UUID) -> Bool {
        purgeStaleEntries()
        return entries.contains { key, value in
            key != windowId && value.connectionId == connectionId
        }
    }

    /// All connection IDs that currently have registered windows.
    internal func allConnectionIds() -> Set<UUID> {
        purgeStaleEntries()
        return Set(entries.values.map(\.connectionId))
    }

    /// Find the first visible window for a connection.
    internal func findWindow(for connectionId: UUID) -> NSWindow? {
        purgeStaleEntries()
        return entries.values
            .filter { $0.connectionId == connectionId }
            .compactMap(\.window)
            .first { $0.isVisible }
    }

    /// Look up the connectionId for a given windowId.
    internal func connectionId(for windowId: UUID) -> UUID? {
        purgeStaleEntries()
        return entries[windowId]?.connectionId
    }

    /// Returns the connectionId associated with the given NSWindow, if registered.
    internal func connectionId(fromWindow window: NSWindow) -> UUID? {
        purgeStaleEntries()
        return entries.values.first(where: { $0.window === window })?.connectionId
    }

    /// Check if any windows are registered for a connection.
    internal func hasWindows(for connectionId: UUID) -> Bool {
        purgeStaleEntries()
        return entries.values.contains { $0.connectionId == connectionId }
    }

    /// Check if a specific window is still registered (with a live NSWindow reference).
    internal func isRegistered(windowId: UUID) -> Bool {
        guard entries[windowId] != nil else { return false }
        purgeStaleEntries()
        return entries[windowId] != nil
    }

    /// Find the first preview window for a connection.
    internal func previewWindow(for connectionId: UUID) -> (windowId: UUID, window: NSWindow)? {
        purgeStaleEntries()
        for (windowId, entry) in entries {
            guard entry.connectionId == connectionId, entry.isPreview else { continue }
            guard let window = entry.window else { continue }
            return (windowId, window)
        }
        return nil
    }

    /// Look up the NSWindow for a given windowId.
    internal func window(for windowId: UUID) -> NSWindow? {
        purgeStaleEntries()
        return entries[windowId]?.window
    }

    /// Update the preview flag for a registered window.
    internal func setPreview(_ isPreview: Bool, for windowId: UUID) {
        entries[windowId]?.isPreview = isPreview
    }

    // MARK: - Source File Tracking

    internal func registerSourceFile(_ url: URL, windowId: UUID) {
        sourceFileWindows[url] = windowId
    }

    internal func unregisterSourceFile(_ url: URL) {
        sourceFileWindows.removeValue(forKey: url)
    }

    internal func unregisterSourceFiles(for windowId: UUID) {
        sourceFileWindows = sourceFileWindows.filter { $0.value != windowId }
    }

    internal func window(forSourceFile url: URL) -> NSWindow? {
        guard let windowId = sourceFileWindows[url] else { return nil }
        guard let window = entries[windowId]?.window else {
            sourceFileWindows.removeValue(forKey: url)
            return nil
        }
        return window
    }

    // MARK: - Private

    /// Remove entries whose window has already been deallocated.
    private func purgeStaleEntries() {
        let staleIds = entries.compactMap { key, value -> UUID? in
            value.window == nil ? key : nil
        }
        for windowId in staleIds {
            let entry = entries.removeValue(forKey: windowId)
            if let observer = entry?.observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func handleWindowClose(_ closedWindow: NSWindow) {
        guard let (windowId, entry) = entries.first(where: { $0.value.window === closedWindow }) else {
            return
        }

        let closedConnectionId = entry.connectionId

        if let observer = entry.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        unregisterSourceFiles(for: windowId)
        entries.removeValue(forKey: windowId)

        let hasRemainingWindows = entries.values.contains {
            $0.connectionId == closedConnectionId && $0.window != nil
        }
        if !hasRemainingWindows {
            Task {
                await DatabaseManager.shared.disconnectSession(closedConnectionId)
            }
        }
    }
}
