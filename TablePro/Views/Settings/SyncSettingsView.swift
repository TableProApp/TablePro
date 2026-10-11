//
//  SyncSettingsView.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProSyncTransport

/// iCloud Sync and what it carries.
///
/// Its own pane rather than a section of the license pane: sync runs on the reader's Apple Account,
/// which is a different identity from the email on a license, and being gated by a license is not
/// on its own a reason to live beside one.
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
        .scrollContentBackground(.hidden)
    }
}

/// The notice that used to float over the account pane. Sync is what stopped, so it is stated here,
/// inline, beside the switch it explains, with the actions that state needs.
private struct SyncNoticeSection: View {
    let notice: SyncNotice

    /// Observed for `isValidating`, which disables Check Again while a check runs. Read off the
    /// singleton directly, the button never learned that a check had started or finished.
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var updater = SoftwareUpdater.shared

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
    private func control(for action: SyncNoticeAction) -> some View {
        switch action {
        case .manageStorage:
            Button(action.title) {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings*AppleIDSettings?iCloud")
            }
        case .openAccountSettings:
            Button(action.title) {
                Self.openSystemSettings("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")
            }
        case .checkForUpdates:
            Button(action.title) {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        case .uploadAgain:
            Button(action.title) {
                Task { await SyncCoordinator.shared.uploadAgain() }
            }
        case .turnOffSync:
            /// Through the setting rather than the coordinator, so the switch's own change handler
            /// turns sync off and settles the password sync flag the same way the switch does.
            Button(action.title) {
                AppSettingsManager.shared.sync.enabled = false
            }
        case .renewLicense:
            Link(action.title, destination: SupportLinks.pricing(.licenseSettings))
        case .checkLicenseAgain:
            Button(action.title) {
                Task { await licenseManager.revalidate() }
            }
            .disabled(licenseManager.isValidating)
        }
    }

    /// Apple's own Notes and Freeform open these Apple Account panes, but the addresses are not
    /// documented, so a release that stops honoring one still gets the person to System Settings.
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
