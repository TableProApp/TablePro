import SwiftUI

internal struct AccountFeaturesPage: View {
    @ObservedObject var access: FeatureAccess

    private var offersPurchase: Bool {
        !access.state.isSignedIn && access.state.entitlement == nil && access.state.legacy == nil
    }

    var body: some View {
        Form {
            Section {
                ForEach(ProFeature.allCases, id: \.self) { feature in
                    AccountFeatureRow(feature: feature, isIncluded: access.isAvailable(feature))
                }
            }

            Section {
                if offersPurchase {
                    LabeledContent {
                        Link(String(localized: "View Plans…"), destination: SupportLinks.pricing(.licenseSettings))
                            .buttonStyle(.bordered)
                            .fixedSize()
                            .countsUpgradeClicks(from: .licenseSettings)
                            .accessibilityIdentifier("account-view-plans")
                    } label: {
                        Text("Paid plans")
                        Text("Compare what each plan includes.")
                    }
                }

                LabeledContent {
                    Link(String(localized: "Learn More…"), destination: SupportLinks.licensingGuide)
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .accessibilityIdentifier("account-licensing-guide")
                } label: {
                    Text("Plans and devices")
                    Text("How plans, devices and offline files work.")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.accountFeatures.pageIdentifier)
    }
}

private struct AccountFeatureRow: View {
    let feature: ProFeature
    let isIncluded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayName)

                Text(feature.featureDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isIncluded {
                Label {
                    Text("Included")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .fixedSize()
            } else {
                Label {
                    Text("Not included")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel(Text(feature.paidPlanRequirement))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
