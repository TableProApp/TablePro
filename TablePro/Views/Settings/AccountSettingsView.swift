//
//  AccountSettingsView.swift
//  TablePro
//

import SwiftUI
import TableProSyncTransport

struct AccountSettingsView: View {
    @Bindable private var syncCoordinator = SyncCoordinator.shared

    var body: some View {
        Form {
            LicenseSection()
            SyncSection()
            LinkedFoldersSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .overlay {
            switch syncCoordinator.syncStatus {
            case .disabled(.licenseExpired):
                licensePausedBanner
            case .disabled(.licenseUnverified):
                licenseUnverifiedBanner
            default:
                EmptyView()
            }
        }
    }

    private var licensePausedBanner: some View {
        banner(String(localized: "Sync paused, Pro license expired")) {
            Link(String(localized: "Renew License…"), destination: SupportLinks.pricing(.licenseSettings))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    /// A license the server has not confirmed for 30 days is not a license to buy again, so the
    /// banner offers the check rather than a purchase.
    private var licenseUnverifiedBanner: some View {
        banner(String(localized: "Sync paused, license not verified")) {
            Button(String(localized: "Check Status")) {
                Task { await LicenseManager.shared.revalidate() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(LicenseManager.shared.isValidating)
        }
    }

    private func banner(_ message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                Spacer()
                action()
            }
            .padding(12)
            .themeMaterial(.banner, .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()

            Spacer()
        }
    }
}

#Preview {
    AccountSettingsView()
        .frame(width: 450, height: 500)
}
