//
//  NSColor+LightDark.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 6/4/25.
//

import AppKit

extension NSColor {
    convenience init(light: NSColor, dark: NSColor) {
        self.init(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                dark
            default:
                light
            }
        }
    }

    /// `withAlphaComponent` on a system or provider color resolves it once, for the appearance current at the call,
    /// and keeps that value. Inside a provider it resolves again for every appearance the color is drawn in.
    func withDynamicAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var tinted = self
            appearance.performAsCurrentDrawingAppearance {
                tinted = self.withAlphaComponent(alpha)
            }
            return tinted
        }
    }
}
