//
//  View+SymbolEffectCompat.swift
//  TablePro
//

import SwiftUI

internal extension View {
    /// `contentTransition(.symbolEffect(.replace))` is macOS 14. On 13 the symbol swaps
    /// without the morph, which is what the view did before the effect was added.
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// `symbolEffect(.pulse, isActive:)` is macOS 14. The fallback pulses the opacity, so a
    /// running sync still reads as running rather than as a static icon.
    @ViewBuilder
    func pulsingSymbol(isActive: Bool) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.pulse, options: .repeating, isActive: isActive)
        } else {
            modifier(OpacityPulse(isActive: isActive))
        }
    }
}

private struct OpacityPulse: ViewModifier {
    let isActive: Bool

    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive && dimmed ? 0.35 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: dimmed
            )
            .onAppear { dimmed = isActive }
            .onChange(of: isActive) { active in dimmed = active }
    }
}
