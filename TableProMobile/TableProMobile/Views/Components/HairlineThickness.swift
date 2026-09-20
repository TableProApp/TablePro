import CoreGraphics

/// A detached view reports a display scale of zero until it joins a window, and `1 / 0` is a
/// constant `NSLayoutConstraint` rejects, so the scale is clamped before it becomes a thickness.
nonisolated enum HairlineThickness {
    static func points(forDisplayScale scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale >= 1 else { return 1 }
        return 1 / scale
    }
}
