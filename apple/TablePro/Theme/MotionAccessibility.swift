#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// Shared with the iOS app.
internal enum MotionAccessibility {
    // `withAnimation(nil)` still performs the change without animating it, so a gated call site needs no second branch.
    internal static func animation(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    #if canImport(AppKit)
    internal static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    #else
    @MainActor internal static var systemReduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
    #endif
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

// For imperative call sites with no environment to read: `withAnimation` captures the animation at the call.
internal func withMotion<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(
        MotionAccessibility.animation(animation, reduceMotion: MotionAccessibility.systemReduceMotion),
        body
    )
}
