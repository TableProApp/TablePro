//
//  ProBadge.swift
//  TablePro
//

import SwiftUI

// Names no plan: which plan includes a feature comes from the server's pricing, not from the app.
struct ProBadge: View {
    let feature: ProFeature

    var body: some View {
        Link(destination: SupportLinks.pricing(.featureGate(feature))) {
            Image(systemName: "lock.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.legibleForeground(on: .orange))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
        }
        .countsUpgradeClicks(from: .featureGate(feature))
        .help(feature.featureDescription)
        .accessibilityLabel(Text(feature.paidPlanRequirement))
        .accessibilityHint(Text("Opens the TablePro pricing page"))
    }
}

#Preview {
    HStack {
        Text("Linked Folders")
        ProBadge(feature: .linkedFolders)
    }
    .padding()
}
