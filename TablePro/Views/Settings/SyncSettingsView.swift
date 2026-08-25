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
            switch syncCoordinator.syncStatus {
            case .disabled(.licenseExpired):
                pausedSection(
                    title: String(localized: "Sync Paused"),
                    message: String(
                        localized: "The license that covers iCloud Sync has expired. Renew it to start syncing again."
                    )
                ) {
                    Link(String(localized: "Renew License"), destination: SupportLinks.pricing(.licenseSettings))
                }
            case .disabled(.licenseUnverified):
                /// Not a license to buy again. The way out is the network, so the action is the
                /// check, never a purchase.
                pausedSection(
                    title: String(localized: "Sync Paused"),
                    message: String(
                        localized: "TablePro has not confirmed this license with the server in 30 days."
                    )
                ) {
                    Button(String(localized: "Check Again")) {
                        Task { await LicenseManager.shared.revalidate() }
                    }
                    .disabled(LicenseManager.shared.isValidating)
                }
            default:
                EmptyView()
            }

            SyncSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The notice that used to float over the account pane. Sync is what stopped, so it is stated
    /// here, inline, beside the switch it explains, with the one action that state needs.
    private func pausedSection(
        title: String,
        message: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    action()
                        .padding(.top, 2)
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    SyncSettingsView()
        .frame(width: 640, height: 500)
}
