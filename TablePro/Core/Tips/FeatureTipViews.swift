//
//  FeatureTipViews.swift
//  TablePro
//

import SwiftUI
import TipKit

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

internal extension View {
    /// The tip layer is TipKit, which is macOS 14. Older systems get the view unchanged.
    @ViewBuilder
    func historyTipAnchor(isEnabled: Bool) -> some View {
        if #available(macOS 14.0, *) {
            modifier(FeatureTipPopoverAnchor(
                tip: FindPastQueriesTip(shortcut: FeatureTipShortcut.display(for: .toggleHistory)),
                isEnabled: isEnabled
            ))
        } else {
            self
        }
    }
}
