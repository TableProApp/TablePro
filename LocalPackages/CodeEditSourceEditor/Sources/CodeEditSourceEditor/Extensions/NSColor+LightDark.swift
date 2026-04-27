//
//  NSColor+LightDark.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/4/25.
//

import AppKit

extension NSColor {
    convenience init(light: NSColor, dark: NSColor) {
        self.init(name: nil) { appearance in
            return switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                dark
            default:
                light
            }
        }
    }
}
