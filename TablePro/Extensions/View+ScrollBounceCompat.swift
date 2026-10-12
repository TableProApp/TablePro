//
//  View+ScrollBounceCompat.swift
//  TablePro
//

import SwiftUI

internal extension View {
    /// `scrollBounceBehavior` arrived in macOS 13.3, and the deployment target is 13.0. Below
    /// that the banner's scroll view bounces even when its content fits, which is cosmetic.
    @ViewBuilder
    func scrollBounceBasedOnSize() -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    /// The `axes:` overload, same availability floor.
    @ViewBuilder
    func scrollBounceBasedOnSize(axes: Axis.Set) -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize, axes: axes)
        } else {
            self
        }
    }
}
