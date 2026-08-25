//
//  SyncSettingsView.swift
//  TablePro
//

import SwiftUI
import TableProSyncTransport

/// iCloud Sync and what it carries.
///
/// Its own pane rather than a section of the license pane: sync runs on the reader's Apple Account,
/// which is a different identity from the email on a license, and being gated by a license is not
/// on its own a reason to live beside one.
struct SyncSettingsView: View {
    @Bindable private var syncCoordinator = SyncCoordinator.shared

    var body: some View {
        Form {
            if case .disabled(.licenseExpired) = syncCoordinator.syncStatus {
                licensePausedSection
            }

            SyncSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The expired-license notice that used to float over the account pane. Sync is what stopped,
    /// so it is stated here, inline, beside the switch it explains.
    private var licensePausedSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Paused")
                        .font(.headline)

                    Text("The license that covers iCloud Sync has expired. Renew it to start syncing again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(String(localized: "Renew License"), destination: SupportLinks.pricing(.licenseSettings))
                        .padding(.top, 2)
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("sync-license-paused")
        }
    }
}

#Preview {
    SyncSettingsView()
        .frame(width: 640, height: 500)
}
