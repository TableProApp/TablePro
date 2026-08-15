//
//  WindowLifecycleMonitor.swift
//  TablePro
//
//  Deterministic NSWindow lifecycle tracker using willCloseNotification.
//  Replaces the fragile SwiftUI onAppear/onDisappear-based NativeTabRegistry
//  with a notification-driven approach that avoids stale entries and timing heuristics.
//

import AppKit
import Combine
import Foundation
import OSLog

@MainActor
internal final class WindowLifecycleMonitor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowLifecycleMonitor")
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
    internal static let shared = WindowLifecycleMonitor()

    private struct Entry {
        let connectionId: UUID
        weak var window: NSWindow?
        var observers: [NSObjectProtocol]
    }

    private var entries: [UUID: Entry] = [:]
    private var sourceFileWindows: [URL: UUID] = [:]
    private var lastFocusedWindowIds: [UUID: UUID] = [:]

    private init() {}

    deinit {
        for entry in entries.values {
            for observer in entry.observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        entries.removeAll()
    }

    // MARK: - Registration

    /// Register a window and start observing its willCloseNotification.
    internal func register(window: NSWindow, connectionId: UUID, windowId: UUID) {
        Self.lifecycleLogger.info(
            "[open] WindowLifecycleMonitor.register windowId=\(windowId, privacy: .public) connId=\(connectionId, privacy: .public) registeredBefore=\(self.entries.count)"
        )
        /// A window id belongs to the SwiftUI content mounted in the window, not to the window, so a
        /// window whose content is rebuilt registers again under a new id. Reconnecting rebuilds it.
        /// Leaving the superseded entry behind makes one window count as two, and everything asking
        /// this registry how many windows a connection has would believe it.
        ///
        /// The connection has to match. One window hosts every open connection now, and each one's
        /// content registers that same window under its own id, so matching on the window alone made
        /// every new connection evict the previous one: the registry held a single connection per
        /// window, named whichever mounted last. `hasWindows`, `findWindow` and `mostRecentWindow`
        /// then answered nothing for connections that were open and on screen.
        let supersededIds = entries.compactMap { key, value -> UUID? in
            key != windowId && value.window === window && value.connectionId == connectionId ? key : nil
        }
        for supersededId in supersededIds {
            guard let superseded = entries.removeValue(forKey: supersededId) else { continue }
            for observer in superseded.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            forgetFocus(windowId: supersededId, connectionId: superseded.connectionId)
        }

        // Remove any existing entry for this windowId to avoid duplicate observers
        if let existing = entries[windowId] {
            if existing.window !== window {
                Self.logger.warning("Re-registering windowId \(windowId) with a different NSWindow")
            }
            for observer in existing.observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closedWindow = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.handleWindowClose(closedWindow)
            }
        }

        let focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey(windowId: windowId)
            }
        }

        entries[windowId] = Entry(
            connectionId: connectionId,
            window: window,
            observers: [closeObserver, focusObserver]
        )
        AppEvents.shared.connectionWindowsChanged.send()
    }

    /// Forgets every window entry for a connection the app no longer hosts.
    ///
    /// Cleanup used to ride on `NSWindow.willCloseNotification`, which was enough while closing a
    /// connection meant closing its window. A connection can now be closed out of a window that
    /// stays open for the others, and nothing told this registry: the entry survived, the workspace
    /// rail kept listing a connection with no workspace, and clicking that row reached a window
    /// that could not host it.
    internal func unregisterWindows(for connectionId: UUID) {
        let staleIds = entries.compactMap { key, value -> UUID? in
            value.connectionId == connectionId ? key : nil
        }
        guard !staleIds.isEmpty else { return }
        for windowId in staleIds {
            unregisterSourceFiles(for: windowId)
            guard let entry = entries.removeValue(forKey: windowId) else { continue }
            for observer in entry.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            forgetFocus(windowId: windowId, connectionId: entry.connectionId)
        }
        AppEvents.shared.connectionWindowsChanged.send()
    }

    /// Remove the UUID mapping for a window.
    internal func unregisterWindow(for windowId: UUID) {
        unregisterSourceFiles(for: windowId)
        guard let entry = entries.removeValue(forKey: windowId) else { return }

        for observer in entry.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        forgetFocus(windowId: windowId, connectionId: entry.connectionId)
        AppEvents.shared.connectionWindowsChanged.send()
    }

    // MARK: - Queries

    /// Return all live windows for a connection.
    internal func windows(for connectionId: UUID) -> [NSWindow] {
        purgeStaleEntries()
        return entries.values
            .filter { $0.connectionId == connectionId }
            .compactMap(\.window)
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

    /// The window a connection was most recently working in.
    ///
    /// Every editor tab is its own window, so `findWindow(for:)` returns an
    /// arbitrary tab. Activating a connection from a switcher has to land on
    /// the tab the user actually left, which is the one that most recently
    /// became key. Falls back to another live window of the same connection when that
    /// window is gone or was never focused. Visibility only ranks candidates and never
    /// excludes one: `isVisible` is false for a miniaturized window, which
    /// `makeKeyAndOrderFront` restores correctly, and filtering it out would reach
    /// another connection's window.
    internal func mostRecentWindow(for connectionId: UUID) -> NSWindow? {
        purgeStaleEntries()
        let eligible = entries
            .filter { $0.value.connectionId == connectionId && $0.value.window != nil }
            .sorted { lhs, rhs in
                let leftVisible = lhs.value.window?.isVisible == true
                let rightVisible = rhs.value.window?.isVisible == true
                guard leftVisible == rightVisible else { return leftVisible }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .map(\.key)
        guard let windowId = Self.resolveWindowId(
            lastFocusedWindowId: lastFocusedWindowIds[connectionId],
            eligibleWindowIds: eligible
        ) else {
            return nil
        }
        return entries[windowId]?.window
    }

    /// Prefers the window the connection was last focused in, falling back to
    /// any eligible window when that one is gone or was never focused.
    internal static func resolveWindowId(
        lastFocusedWindowId: UUID?,
        eligibleWindowIds: [UUID]
    ) -> UUID? {
        if let lastFocusedWindowId, eligibleWindowIds.contains(lastFocusedWindowId) {
            return lastFocusedWindowId
        }
        return eligibleWindowIds.first
    }

    /// The window a connection was last focused in, if one has been recorded.
    internal func lastFocusedWindowId(for connectionId: UUID) -> UUID? {
        lastFocusedWindowIds[connectionId]
    }

    /// The active window for a connection, preferring `candidate` (typically the
    /// key window) when it belongs to this connection. Each editor tab is a
    /// separate window in a native tab group, so `findWindow` returns an
    /// arbitrary tab's window; anchoring a connection-scoped sheet there would
    /// switch the selected tab. Preferring the key window keeps the user on the
    /// tab they triggered the action from.
    internal func activeWindow(for connectionId: UUID, preferring candidate: NSWindow?) -> NSWindow? {
        if let candidate, self.connectionId(forWindow: candidate) == connectionId {
            return candidate
        }
        return findWindow(for: connectionId)
    }

    /// Look up the connectionId for a given windowId.
    internal func connectionId(for windowId: UUID) -> UUID? {
        purgeStaleEntries()
        return entries[windowId]?.connectionId
    }

    /// Returns the connectionId associated with the given NSWindow, if registered.
    internal func connectionId(forWindow window: NSWindow) -> UUID? {
        purgeStaleEntries()
        return entries.values.first(where: { $0.window === window })?.connectionId
    }

    /// Returns the internal windowId for a given NSWindow, if registered.
    internal func windowId(forWindow window: NSWindow) -> UUID? {
        purgeStaleEntries()
        return entries.first(where: { $0.value.window === window })?.key
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

    /// Look up the NSWindow for a given windowId.
    internal func window(for windowId: UUID) -> NSWindow? {
        purgeStaleEntries()
        return entries[windowId]?.window
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
            guard let entry = entries.removeValue(forKey: windowId) else { continue }
            for observer in entry.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            forgetFocus(windowId: windowId, connectionId: entry.connectionId)
        }
    }

    private func handleWindowDidBecomeKey(windowId: UUID) {
        guard let entry = entries[windowId] else { return }
        guard lastFocusedWindowIds[entry.connectionId] != windowId else { return }
        lastFocusedWindowIds[entry.connectionId] = windowId
        AppEvents.shared.connectionWindowsChanged.send()
    }

    private func forgetFocus(windowId: UUID, connectionId: UUID) {
        guard lastFocusedWindowIds[connectionId] == windowId else { return }
        lastFocusedWindowIds.removeValue(forKey: connectionId)
    }

    /// Every connection the closing window presented, not the first one found.
    ///
    /// A window hosts all of them now, so taking one entry left the rest registered against a window
    /// that was going away, and left their sessions connected: drivers, SSH tunnels and health
    /// monitors running with no window and no workspace behind them until the app quit.
    private func handleWindowClose(_ closedWindow: NSWindow) {
        let closing = entries.compactMap { key, value -> (UUID, Entry)? in
            value.window === closedWindow ? (key, value) : nil
        }
        guard !closing.isEmpty else {
            Self.lifecycleLogger.info(
                "[close] handleWindowClose: unknown window (not in registry)"
            )
            return
        }

        for (windowId, entry) in closing {
            Self.lifecycleLogger.info(
                "[close] willCloseNotification -> handleWindowClose windowId=\(windowId, privacy: .public) connId=\(entry.connectionId, privacy: .public)"
            )
            for observer in entry.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            unregisterSourceFiles(for: windowId)
            entries.removeValue(forKey: windowId)
            forgetFocus(windowId: windowId, connectionId: entry.connectionId)
        }
        AppEvents.shared.connectionWindowsChanged.send()

        for connectionId in Set(closing.map(\.1.connectionId)) {
            let hasRemainingWindows = entries.values.contains {
                $0.connectionId == connectionId && $0.window != nil
            }
            guard !hasRemainingWindows else { continue }
            Self.lifecycleLogger.info(
                "[close] handleWindowClose disconnecting connId=\(connectionId, privacy: .public) totalEntries=\(self.entries.count)"
            )
            Task {
                let t0 = Date()
                await DatabaseManager.shared.disconnectSession(connectionId)
                Self.lifecycleLogger.info(
                    "[close] (from handleWindowClose) disconnectSession done connId=\(connectionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
                )
            }
        }
    }
}
