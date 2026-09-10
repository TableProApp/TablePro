//
//  MotionAccessibility.swift
//  TablePro
//

import AppKit
import SwiftUI

internal enum MotionAccessibility {
    /// `withAnimation(nil)` still performs the change, it just does not animate it, so a gated
    /// call site never needs a second branch for the reduced case.
    internal static func animation(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    internal static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(
            MotionAccessibility.animation(animation, reduceMotion: reduceMotion),
            value: value
        )
    }
}

internal extension View {
    func motionAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

/// For imperative call sites, where there is no environment to read. `withAnimation` captures the
/// animation at the call, so the setting has to be read here rather than passed down.
internal func withMotion<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(
        MotionAccessibility.animation(animation, reduceMotion: MotionAccessibility.systemReduceMotion),
        body
    )
}
