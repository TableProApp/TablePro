//
//  SyncStatusIndicator.swift
//  TablePro
//

import SwiftUI
import TableProSyncTransport

struct SyncStatusIndicator: View {
    let onActivateLicense: () -> Void

    @ObservedObject private var syncCoordinator = SyncCoordinator.shared

    var body: some View {
        let presentation = SyncStatusPresentation(
            status: syncCoordinator.syncStatus,
            lastSyncDate: syncCoordinator.lastSyncDate
        )
        if presentation.showsIndicator {
            Button {
                handleTap()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: presentation.symbolName)
                        .symbolReplaceTransition()
                        .pulsingSymbol(isActive: syncCoordinator.syncStatus.isSyncing)
                    Text(presentation.indicatorLabel)
                        .contentTransition(.numericText())
                }
                .font(.subheadline)
                .foregroundStyle(foregroundStyle(for: presentation))
                .motionAnimation(.default, value: syncCoordinator.syncStatus)
            }
            .buttonStyle(.plain)
            .help(presentation.helpText)
        }
    }

    private func foregroundStyle(for presentation: SyncStatusPresentation) -> AnyShapeStyle {
        if presentation.isWarning {
            return AnyShapeStyle(.orange)
        }
        return syncCoordinator.syncStatus.isSyncing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }

    /// An unverified license is the one degraded state activation cannot mend, so it retries the
    /// check instead of opening a sheet that asks for a key the person already gave.
    private func handleTap() {
        switch syncCoordinator.syncStatus {
        case .disabled(.licenseRequired), .disabled(.licenseExpired):
            onActivateLicense()
        case .disabled(.licenseUnverified):
            Task { await LicenseManager.shared.revalidate() }
        case .idle, .syncing, .error, .disabled(.userDisabled):
            WindowOpener.shared.openSettings(tab: .sync)
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        SyncStatusIndicator(onActivateLicense: {})
    }
    .padding()
}
