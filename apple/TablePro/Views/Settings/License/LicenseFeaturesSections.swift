//
//  LicenseFeaturesSections.swift
//  TablePro
//

import SwiftUI

struct LicenseFeaturesSections: View {
    let groups: [LicenseFeatureGroup]
    let offersPurchase: Bool

    var body: some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.features, id: \.self) { feature in
                    LicenseFeatureRow(feature: feature)
                }
            } header: {
                header(for: group)
            } footer: {
                if group.id == groups.last?.id {
                    footer
                }
            }
        }
    }

    private func header(for group: LicenseFeatureGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "%@ Plan"), group.tier.displayName))

                if let includedTier = group.includedTier {
                    Text(String(format: String(localized: "Includes everything in %@."), includedTier.displayName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            accessLabel(group.access)
        }
    }

    @ViewBuilder
    private func accessLabel(_ access: ProFeatureAccess) -> some View {
        switch access {
        case .available:
            Label {
                Text("Included")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .requiresUpgrade:
            Link("Upgrade Plan", destination: SupportLinks.pricing(.licenseSettings))
                .accessibilityIdentifier("license-upgrade-plan")
        case .unlicensed, .expired, .validationFailed:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if offersPurchase {
                Link("Buy a License", destination: SupportLinks.pricing(.licenseSettings))
            }

            Link("Learn More About Licensing", destination: SupportLinks.licensingGuide)
        }
        .font(.callout)
    }
}

private struct LicenseFeatureRow: View {
    let feature: ProFeature

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.displayName)

                Text(feature.featureDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
