//
//  LicenseSettingsView.swift
//  TablePro
//

import SwiftUI

// Keyed on holding a license; entitlement decides only whether a renewal field appears beside it.
struct LicenseSettingsView: View {
    @ObservedObject private var licenseManager = LicenseManager.shared

    private var notice: LicenseNotice? {
        LicensePresentation.notice(
            status: licenseManager.status,
            daysUntilExpiry: licenseManager.daysUntilExpiry,
            isExpired: licenseManager.license?.isExpired ?? false,
            hasLicense: licenseManager.license != nil
        )
    }

    var body: some View {
        Form {
            if let notice {
                LicenseNoticeSection(notice: notice)
            }

            // Keyed on holding a licence: a lapsed one still has seats to release and a renewal to enter.
            if let license = licenseManager.license {
                identitySection(license)

                if LicensePresentation.showsRenewalField(status: licenseManager.status) {
                    renewalSection
                }

                detailsSection(license)
                LicenseDevicesSection()
                if licenseManager.showsTeamRoster {
                    LicenseTeamSection()
                }
                LicenseFeaturesSections(groups: featureGroups, offersPurchase: false)
                actionsSection
            } else {
                landingSection
                LicenseFeaturesSections(groups: featureGroups, offersPurchase: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Licensed

    private func identitySection(_ license: License) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: sealSymbol)
                    .font(.largeTitle)
                    .foregroundStyle(sealTint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(license.email)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(planDescription(license))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    // The notice shows a failed check itself when it offers the retry.
                    if notice?.action != .retryValidation {
                        LicenseCheckFailureLine()
                            .padding(.top, 2)
                    }
                }

                Spacer()

                Button(String(localized: "Refresh")) {
                    Task { await licenseManager.refreshLicenseAndDevices() }
                }
                // `revalidate` releases `isValidating` before the seat list is requested.
                .disabled(licenseManager.isValidating || licenseManager.isRefreshingDevices)
                .accessibilityIdentifier("license-refresh")
            }
            .padding(.vertical, 4)
        }
    }

    private func detailsSection(_ license: License) -> some View {
        Section {
            LicenseKeyRow(key: license.key)
        }
    }

    private var actionsSection: some View {
        Section {
            Link(String(localized: "Manage Account"), destination: SupportLinks.account)

            Button(String(localized: "Deactivate on This Mac…"), role: .destructive) {
                Task { @MainActor in
                    let confirmed = await AlertHelper.confirmDestructive(
                        title: String(localized: "Deactivate this license?"),
                        message: String(
                            localized: "Paid features stop on this Mac right away. You can activate this license again later."
                        ),
                        confirmButton: String(localized: "Deactivate"),
                        cancelButton: String(localized: "Cancel")
                    )
                    guard confirmed else { return }
                    let reachedServer = await licenseManager.deactivate()
                    if !reachedServer {
                        licenseManager.releaseErrorMessage = LicenseManager.unreachableServerSeatMessage
                    }
                }
            }
            .disabled(licenseManager.isValidating)
            .accessibilityIdentifier("license-deactivate")
        }
    }

    // MARK: - Not entitled

    private var renewalSection: some View {
        Section {
            LicenseActivationForm()
                .padding(.vertical, 4)
        }
    }

    private var landingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unlock the paid features")
                        .font(.headline)

                    Text("Everything else keeps working without a license, with nothing counting down.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let releaseError = licenseManager.releaseErrorMessage {
                    Label(releaseError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LicenseActivationForm()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private var featureGroups: [LicenseFeatureGroup] {
        LicensePresentation.featureGroups(status: licenseManager.status, tier: licenseManager.currentTier)
    }

    // The seal follows entitlement: a green seal on a license that is not working would mislead.
    private var sealSymbol: String {
        LicensePresentation.showsLicensedLayout(status: licenseManager.status)
            ? "checkmark.seal.fill"
            : "seal"
    }

    private var sealTint: Color {
        LicensePresentation.showsLicensedLayout(status: licenseManager.status) ? .green : .secondary
    }

    private func planDescription(_ license: License) -> String {
        LicensePresentation.planDescription(
            tier: license.tier,
            billingCycle: license.billingCycle,
            expiry: license.expiresAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
        )
    }
}

struct LicenseKeyRow: View {
    let key: String

    var body: some View {
        LabeledContent(String(localized: "License key")) {
            HStack(spacing: 8) {
                Text(LicensePresentation.maskedKey(key))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    // Not `.accessibilityLabel`: on a line-limited Text in a LabeledContent, SwiftUI
                    // reads that label back through its platform element until the stack overflows.
                    .accessibilityRepresentation {
                        Text(String(localized: "License key, hidden"))
                    }

                Button(String(localized: "Copy Key")) {
                    ClipboardService.shared.writeSecretText(key)
                }
                .controlSize(.small)
                .accessibilityIdentifier("license-copy-key")
            }
        }
    }
}

private struct LicenseNoticeSection: View {
    let notice: LicenseNotice

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.headline)

                    Text(notice.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let action = notice.action {
                        LicenseNoticeActionButton(action: action, referrer: .licenseSettings)
                            .padding(.top, 2)
                    }

                    if notice.action == .retryValidation {
                        LicenseCheckFailureLine()
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var symbol: String {
        switch notice.tone {
        case .informational: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.tone {
        case .informational: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

#Preview {
    LicenseSettingsView()
        .frame(width: 640, height: 500)
}
