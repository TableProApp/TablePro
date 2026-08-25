//
//  LicenseSettingsView.swift
//  TablePro
//

import SwiftUI

/// The License pane: what you hold, whether it is working, and the seats it covers.
///
/// The layout is keyed on holding a license, and entitlement decides only whether a renewal field
/// appears alongside it. A lapsed license still has seats to release and billing to open.
struct LicenseSettingsView: View {
    private let licenseManager = LicenseManager.shared

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

            /// Keyed on holding a licence, not on it being in good standing. A lapsed licence
            /// still has seats worth releasing and billing worth opening, and hiding them behind
            /// entitlement takes the renewal route away at exactly the moment it is needed.
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
                actionsSection
            } else {
                landingSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                }

                Spacer()

                Button(String(localized: "Refresh")) {
                    Task { await licenseManager.refreshLicenseAndDevices() }
                }
                /// `revalidate` releases `isValidating` before the seat list is even requested, so
                /// gating on it alone re-enabled the button while the longer half was still running
                /// and let a second Refresh start on top of the first.
                .disabled(licenseManager.isValidating || licenseManager.isRefreshingDevices)
                .accessibilityIdentifier("license-refresh")
            }
            .padding(.vertical, 4)
        }
    }

    /// Deliberately short. The header already carries who the license is for and what it is, so
    /// repeating the email and the plan here is the clutter this pane was rebuilt to remove: every
    /// fact appears once, and only facts somebody acts on appear at all.
    private func detailsSection(_ license: License) -> some View {
        Section {
            LabeledContent(String(localized: "License key")) {
                HStack(spacing: 8) {
                    /// Enough of the key to tell which licence this is, and no more. A full-length
                    /// mask is the same secret-shaped run of dots for everyone, so it earned its
                    /// width by being unreadable and then lost the end of itself to truncation.
                    Text(LicensePresentation.maskedKey(license.key))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .accessibilityLabel(Text(String(localized: "License key, hidden")))

                    Button(String(localized: "Copy Key")) {
                        ClipboardService.shared.writeSecretText(license.key)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("license-copy-key")
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Link(String(localized: "Manage Billing"), destination: SupportLinks.account)

            Button(String(localized: "Deactivate on This Mac…"), role: .destructive) {
                Task { @MainActor in
                    let confirmed = await AlertHelper.confirmDestructive(
                        title: String(localized: "Deactivate this license?"),
                        message: String(
                            localized: "Pro features stop on this Mac right away. You can activate this license again later."
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

    /// The way back in for somebody who already holds a lapsed licence: just the field and the
    /// purchase link, without the pitch, which they have plainly already read.
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
                    Text("Unlock the Pro features")
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

                Link("Buy a License", destination: SupportLinks.pricing(.licenseSettings))
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    /// A seal that stays green for a license that is not working would be the pane telling a
    /// comfortable lie, so it follows entitlement.
    private var sealSymbol: String {
        LicensePresentation.showsLicensedLayout(status: licenseManager.status)
            ? "checkmark.seal.fill"
            : "seal"
    }

    private var sealTint: Color {
        LicensePresentation.showsLicensedLayout(status: licenseManager.status) ? .green : .secondary
    }

    /// One line under the email carrying what was bought and how long it runs, so neither needs a
    /// row of its own further down.
    private func planDescription(_ license: License) -> String {
        LicensePresentation.planDescription(
            tier: license.tier,
            billingCycle: license.billingCycle,
            expiry: license.expiresAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
        )
    }}

/// A degraded state, stated where it applies rather than floated over the pane.
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
                        actionControl(action)
                            .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func actionControl(_ action: LicenseNoticeAction) -> some View {
        switch action {
        case .renew:
            Link(String(localized: "Renew License"), destination: SupportLinks.pricing(.licenseSettings))
        case .purchase:
            Link(String(localized: "Buy a License"), destination: SupportLinks.pricing(.licenseSettings))
        case .retryValidation:
            Button(String(localized: "Try Again")) {
                Task { await LicenseManager.shared.revalidate() }
            }
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
