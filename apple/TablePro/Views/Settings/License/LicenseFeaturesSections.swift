//
//  LicenseFeaturesSections.swift
//  TablePro
//

import SwiftUI

struct LicenseFeaturesSections: View {
    @ObservedObject var featureAccess: FeatureAccess

    var body: some View {
        Section {
            ForEach(ProFeature.allCases, id: \.self) { feature in
                LicenseFeatureRow(feature: feature, isIncluded: featureAccess.isAvailable(feature))
            }
        } header: {
            Text("Features")
        } footer: {
            HStack(spacing: 16) {
                if featureAccess.supportAudience == .prospect {
                    Link("Buy a License", destination: SupportLinks.pricing(.licenseSettings))
                }

                Link("Learn More About Licensing", destination: SupportLinks.licensingGuide)
            }
            .font(.callout)
        }
    }
}

private struct LicenseFeatureRow: View {
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
