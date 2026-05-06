//
//  MainEditorWindowState.swift
//  TablePro
//

import AppKit
import Foundation
import Observation
import os
import SwiftUI

@MainActor
@Observable
internal final class MainEditorWindowState {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
    private static let inspectorPresentedKey = "com.TablePro.rightPanel.isPresented"

    let payload: EditorTabPayload?

    var currentSession: ConnectionSession?
    var sessionState: SessionStateFactory.SessionState?
    var rightPanelState: RightPanelState?
    var inspectorPresented: Bool
    var sidebarColumnVisibility: NavigationSplitViewVisibility
    var windowTitle: String

    @ObservationIgnored private var closingSessionId: UUID?
    @ObservationIgnored private var connectionStatusObserver: NSObjectProtocol?
    @ObservationIgnored private weak var hostWindow: NSWindow?

    init(payload: EditorTabPayload?, sessionState: SessionStateFactory.SessionState?) {
        self.payload = payload
        self.inspectorPresented = UserDefaults.standard.bool(forKey: Self.inspectorPresentedKey)

        let resolvedSession = MainEditorWindowState.resolveSession(payload: payload)
        self.currentSession = resolvedSession

        let resolvedState: SessionStateFactory.SessionState?
        let resolvedRightPanel: RightPanelState?
        let resolvedVisibility: NavigationSplitViewVisibility

        if let session = resolvedSession {
            resolvedRightPanel = RightPanelState()
            if let payloadId = payload?.id,
               let pending = SessionStateFactory.consumePending(for: payloadId) {
                resolvedState = pending
                Self.lifecycleLogger.info(
                    "[open] MainEditorWindowState consumed pending payloadId=\(payloadId, privacy: .public)"
                )
            } else if let providedState = sessionState {
                resolvedState = providedState
            } else {
                resolvedState = SessionStateFactory.create(connection: session.connection, payload: payload)
            }
            resolvedVisibility = .all
        } else {
            resolvedRightPanel = nil
            resolvedState = nil
            resolvedVisibility = .detailOnly
        }

        self.rightPanelState = resolvedRightPanel
        self.sessionState = resolvedState
        self.sidebarColumnVisibility = resolvedVisibility
        self.windowTitle = MainEditorWindowState.makeInitialTitle(
            payload: payload,
            sessionState: resolvedState
        )
    }

    deinit {
        if let observer = connectionStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func attachWindow(_ window: NSWindow) {
        hostWindow = window
        window.title = windowTitle
        if let session = currentSession {
            window.subtitle = session.connection.name
        }
        installObservers()
    }

    func wireCoordinatorIfNeeded() {
        guard let coordinator = sessionState?.coordinator else { return }
        coordinator.editorWindowState = self
    }

    // MARK: - Inspector

    func showInspector() {
        inspectorPresented = true
        UserDefaults.standard.set(true, forKey: Self.inspectorPresentedKey)
    }

    func hideInspector() {
        inspectorPresented = false
        UserDefaults.standard.set(false, forKey: Self.inspectorPresentedKey)
    }

    func toggleInspector() {
        if inspectorPresented {
            hideInspector()
        } else {
            showInspector()
        }
    }

    // MARK: - Sidebar

    var isSidebarCollapsed: Bool {
        sidebarColumnVisibility == .detailOnly
    }

    func setSidebarTab(_ tab: SidebarTab) {
        guard let connectionId = currentSession?.connection.id else { return }
        let sidebarState = SharedSidebarState.forConnection(connectionId)

        if isSidebarCollapsed {
            sidebarState.selectedSidebarTab = tab
            sidebarColumnVisibility = .all
        } else if sidebarState.selectedSidebarTab == tab {
            sidebarColumnVisibility = .detailOnly
        } else {
            sidebarState.selectedSidebarTab = tab
        }
    }

    // MARK: - Title

    func updateWindowTitle(_ title: String) {
        windowTitle = title
        hostWindow?.title = title
    }

    // MARK: - Connection Status

    private func installObservers() {
        guard connectionStatusObserver == nil else { return }
        connectionStatusObserver = NotificationCenter.default.addObserver(
            forName: .connectionStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConnectionStatusChange()
            }
        }
        handleConnectionStatusChange()
    }

    private func handleConnectionStatusChange() {
        guard closingSessionId == nil else { return }

        let sessions = DatabaseManager.shared.activeSessions
        let connectionId = payload?.connectionId
            ?? currentSession?.id
            ?? DatabaseManager.shared.currentSessionId

        guard let sid = connectionId else {
            if currentSession != nil { currentSession = nil }
            return
        }

        guard let newSession = sessions[sid] else {
            if currentSession?.id == sid {
                Self.lifecycleLogger.info(
                    "[close] MainEditorWindowState session removed connId=\(sid, privacy: .public)"
                )
                closingSessionId = sid
                rightPanelState?.teardown()
                rightPanelState = nil
                sessionState?.coordinator.teardown()
                sessionState = nil
                currentSession = nil
                sidebarColumnVisibility = .detailOnly
            }
            return
        }

        if let existing = currentSession, existing.isContentViewEquivalent(to: newSession) {
            return
        }
        currentSession = newSession

        if payload?.tableName == nil,
           windowTitle == String(localized: "SQL Query") || windowTitle.hasSuffix(" Query") {
            updateWindowTitle(newSession.connection.name)
        }
        hostWindow?.subtitle = newSession.connection.name

        if rightPanelState == nil {
            rightPanelState = RightPanelState()
        }
        if sessionState == nil {
            let state = SessionStateFactory.create(connection: newSession.connection, payload: payload)
            sessionState = state
            state.coordinator.editorWindowState = self
        }

        sidebarColumnVisibility = .all
    }

    // MARK: - Static helpers

    private static func resolveSession(payload: EditorTabPayload?) -> ConnectionSession? {
        if let connectionId = payload?.connectionId {
            return DatabaseManager.shared.activeSessions[connectionId]
        }
        if let currentId = DatabaseManager.shared.currentSessionId {
            return DatabaseManager.shared.activeSessions[currentId]
        }
        return nil
    }

    private static func makeInitialTitle(
        payload: EditorTabPayload?,
        sessionState: SessionStateFactory.SessionState?
    ) -> String {
        if payload?.tabType == .serverDashboard {
            return String(localized: "Server Dashboard")
        }
        if payload?.tabType == .erDiagram {
            return String(localized: "ER Diagram")
        }
        if payload?.tabType == .createTable {
            return String(localized: "Create Table")
        }
        if payload?.tabType == .terminal {
            return String(localized: "Terminal")
        }
        if let tabTitle = payload?.tabTitle {
            return tabTitle
        }
        if let tableName = payload?.tableName {
            return tableName
        }
        if payload?.intent == .newEmptyTab,
           let tabTitle = sessionState?.coordinator.tabManager.selectedTab?.title {
            return tabTitle
        }
        if let connectionId = payload?.connectionId,
           let connection = DatabaseManager.shared.activeSessions[connectionId]?.connection {
            let langName = PluginManager.shared.queryLanguageName(for: connection.type)
            return "\(langName) Query"
        }
        return String(localized: "SQL Query")
    }
}
