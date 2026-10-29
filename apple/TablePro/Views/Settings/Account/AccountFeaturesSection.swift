//
//  AccountFeaturesSection.swift
//  TablePro
//

import SwiftUI

struct AccountFeaturesSection: View {
    @ObservedObject var access: FeatureAccess
    let offersPurchase: Bool

    var body: some View {
        Section {
            ForEach(ProFeature.allCases, id: \.self) { feature in
                AccountFeatureRow(feature: feature, isIncluded: access.isAvailable(feature))
            }
        } header: {
            Text("Features")
        } footer: {
            HStack(spacing: 16) {
                if offersPurchase {
                    Link("Buy a License", destination: SupportLinks.pricing(.licenseSettings))
                }

                Link("Learn More About Licensing", destination: SupportLinks.licensingGuide)
            }
            .font(.callout)
        }
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isIncluded {
                Label {
                    Text("Included")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(feature.paidPlanRequirement))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
