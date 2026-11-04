//
//  View+UpgradeClicks.swift
//  TablePro
//

import SwiftUI

extension View {
    // A Link has no action of its own; its click reaches the openURL action before the browser opens.
    func countsUpgradeClicks(from referrer: SupportReferrer) -> some View {
        environment(\.openURL, OpenURLAction { url in
            Telemetry.shared.upgradeClicked(from: referrer)
            return .systemAction(url)
        })
    }
}
