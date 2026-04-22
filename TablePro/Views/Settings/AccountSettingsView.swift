//
//  AccountSettingsView.swift
//  TablePro
//

import SwiftUI

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
            if case .disabled(.licenseExpired) = syncCoordinator.syncStatus {
                licensePausedBanner
            }
        }
    }

    private var licensePausedBanner: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(String(localized: "Sync paused — Pro license expired"))
                    .font(.callout)
                Spacer()
                Link(String(localized: "Renew License..."), destination: LicenseConstants.pricingURL)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()

            Spacer()
        }
    }
}

#Preview {
    AccountSettingsView()
        .frame(width: 450, height: 500)
}
