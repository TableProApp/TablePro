//
//  SyncStatusIndicator.swift
//  TablePro
//
//  Small cloud icon showing sync status in the welcome window footer
//

import SwiftUI

struct SyncStatusIndicator: View {
    @Environment(\.openSettings) private var openSettings
    private let syncCoordinator = SyncCoordinator.shared
    @State private var showActivationSheet = false

    var body: some View {
        if shouldShow {
            Button {
                handleTap()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: syncCoordinator.syncStatus.isSyncing)
                    Text(statusLabel)
                        .contentTransition(.numericText())
                }
                .font(.subheadline)
                .foregroundStyle(foregroundStyle)
                .animation(.default, value: syncCoordinator.syncStatus)
            }
            .buttonStyle(.plain)
            .help(helpText)
            .sheet(isPresented: $showActivationSheet) {
                LicenseActivationSheet()
            }
        }
    }

    // MARK: - State Mapping

    private var shouldShow: Bool {
        if case .disabled(.userDisabled) = syncCoordinator.syncStatus {
            return false
        }
        return true
    }

    private var iconName: String {
        switch syncCoordinator.syncStatus {
        case .idle:
            return "cloud.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.icloud"
        case .disabled(.noAccount):
            return "icloud.slash"
        case .disabled(.licenseRequired), .disabled(.licenseExpired):
            return "xmark.icloud"
        case .disabled(.userDisabled):
            return "icloud.slash"
        }
    }

    private var statusLabel: String {
        switch syncCoordinator.syncStatus {
        case .idle:
            return String(localized: "Synced")
        case .syncing:
            return String(localized: "Syncing...")
        case .error:
            return String(localized: "Sync Error")
        case .disabled(.noAccount):
            return String(localized: "No iCloud")
        case .disabled(.licenseRequired), .disabled(.licenseExpired):
            return String(localized: "Sync Off")
        case .disabled(.userDisabled):
            return ""
        }
    }

    private var foregroundStyle: some ShapeStyle {
        switch syncCoordinator.syncStatus {
        case .idle:
            return AnyShapeStyle(.tertiary)
        case .syncing:
            return AnyShapeStyle(.secondary)
        case .error:
            return AnyShapeStyle(Color(nsColor: .systemOrange))
        case .disabled:
            return AnyShapeStyle(.tertiary)
        }
    }

    private var helpText: String {
        switch syncCoordinator.syncStatus {
        case .idle:
            if let lastSync = syncCoordinator.lastSyncDate {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let relative = formatter.localizedString(for: lastSync, relativeTo: Date())
                return String(format: String(localized: "Last synced %@"), relative)
            }
            return String(localized: "iCloud Sync is active")
        case .syncing:
            return String(localized: "Syncing with iCloud...")
        case .error(let error):
            return error.localizedDescription
        case .disabled(.noAccount):
            return String(localized: "Sign in to iCloud to enable sync")
        case .disabled(.licenseRequired):
            return String(localized: "Pro license required for iCloud Sync")
        case .disabled(.licenseExpired):
            return String(localized: "License expired — sync paused")
        case .disabled(.userDisabled):
            return ""
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch syncCoordinator.syncStatus {
        case .disabled(.licenseRequired), .disabled(.licenseExpired):
            showActivationSheet = true
        default:
            UserDefaults.standard.set(SettingsTab.sync.rawValue, forKey: "selectedSettingsTab")
            openSettings()
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        SyncStatusIndicator()
    }
    .padding()
}
