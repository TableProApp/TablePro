//
//  SyncSettingsView.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProSyncTransport

// Its own pane: sync runs on the Apple Account, a different identity from the email on a license.
struct SyncSettingsView: View {
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared

    var body: some View {
        Form {
            if let notice = SyncStatusPresentation(status: syncCoordinator.syncStatus).notice {
                SyncNoticeSection(notice: notice)
            }

            SyncSection()
        }
        .formStyle(.grouped)
    }
}

private struct SyncNoticeSection: View {
    let notice: SyncNotice

    @ObservedObject private var syncCoordinator = SyncCoordinator.shared
    @ObservedObject private var updates = UpdateCenter.shared

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncSettingsView")

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.symbolName)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.headline)

                    Text(notice.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !notice.actions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(notice.actions, id: \.self) { action in
                                control(for: action)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func control(for action: SyncStatusAction) -> some View {
        switch action {
        case .tryAgain:
            Button(action.title) {
                Task { await syncCoordinator.syncNow() }
            }
            .disabled(syncCoordinator.syncStatus.isSyncing)
        case .manageStorage:
            Button(action.title) {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings*AppleIDSettings?iCloud")
            }
        case .openAccountSettings:
            Button(action.title) {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
            }
        case .checkForUpdates:
            Button(updates.status.appUpdateTitle) {
                updates.performAppUpdateAction()
            }
            .disabled(!updates.isAppUpdateActionEnabled)
        case .uploadAgain:
            Button(action.title) {
                Task { await SyncCoordinator.shared.uploadAgain() }
            }
        case .turnOffSync:
            // Through the setting, which also turns password sync off and stops the coordinator.
            Button(action.title) {
                AppSettingsManager.shared.sync.enabled = false
            }
        }
    }

    // Notes and Freeform open these Apple Account panes, but the addresses are not documented.
    private static func openSystemSettings(_ address: String) {
        if let url = URL(string: address), NSWorkspace.shared.open(url) {
            return
        }
        logger.notice("System Settings did not open the Apple Account pane; opening System Settings instead")
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

#Preview {
    SyncSettingsView()
        .frame(width: 640, height: 500)
}
