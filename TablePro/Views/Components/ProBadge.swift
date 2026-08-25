//
//  ProBadge.swift
//  TablePro
//

import SwiftUI

/// Marks a control a license unlocks, and is the route out of that control.
///
/// The badge carries the feature it stands for so it can say what the feature does and open the
/// pricing page tagged with which gate was met. Without that, a disabled toggle beside a bare
/// capsule is a dead end: it names no feature, explains nothing, and leads nowhere.
struct ProBadge: View {
    let feature: ProFeature

    var body: some View {
        Link(destination: SupportLinks.pricing(.featureGate(feature))) {
            Text("PRO")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.legibleForeground(on: .orange))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
        }
        .help(feature.featureDescription)
        .accessibilityLabel(Text(String(format: String(localized: "%@, Pro feature"), feature.displayName)))
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
