//
//  ChatComposerChrome.swift
//  TablePro
//

import AppKit
import SwiftUI

internal enum ChatComposerMetrics {
    /// One owner for the composer's curvature, read by the SwiftUI background shape and by the
    /// scroll view's focus ring mask, so the ring cannot drift from the surface it wraps.
    static let cornerRadius: CGFloat = 16
}

/// Whether the composer paints its own focus highlight, which is a user preference first and a
/// system accessibility decision second. The highlight is a wide translucent colour wash, so
/// Reduce Transparency and Increase Contrast both mean "not this", the same answer
/// `SolidSurfacePreference` gives for every other translucent surface in the app.
///
/// Reduce Motion is deliberately absent: the gradient is static, and the only motion is the
/// crossfade, which `motionAnimation` already gates at the call site.
internal enum ComposerHighlightPreference {
    static func paintsHighlight(
        enabled: Bool,
        reduceTransparency: Bool,
        contrast: ColorSchemeContrast
    ) -> Bool {
        guard enabled else { return false }
        return !SolidSurfacePreference.prefersSolid(reduceTransparency: reduceTransparency, contrast: contrast)
    }

    /// The composer draws exactly one focus affordance. When it paints its own, AppKit must not
    /// add a second; when it does not, the system ring is the whole indication that the field has
    /// keyboard focus, so it has to be on.
    static func focusRingType(paintsHighlight: Bool) -> NSFocusRingType {
        paintsHighlight ? .none : .exterior
    }
}
