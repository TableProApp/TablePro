//
//  FeatureTipViews.swift
//  TablePro
//

import SwiftUI
import TipKit

internal struct FeatureTipInline<TipType: Tip>: View {
    let tip: TipType

    var body: some View {
        if FeatureTipsBootstrap.allows(tip.id) {
            TipView(tip)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }
}

internal struct FeatureTipPopoverAnchor<TipType: Tip>: ViewModifier {
    let tip: TipType
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled, FeatureTipsBootstrap.allows(tip.id) {
            content.popoverTip(tip, arrowEdge: .top)
        } else {
            content
        }
    }
}

internal enum FeatureTipShortcut {
    @MainActor
    static func display(for action: ShortcutAction) -> String? {
        AppSettingsManager.shared.keyboard.shortcut(for: action)?.displayString
    }
}
