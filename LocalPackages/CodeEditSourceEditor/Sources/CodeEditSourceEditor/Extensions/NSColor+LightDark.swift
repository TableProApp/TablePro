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
            return switch appearance.name {
            case .aqua:
                light
            case .darkAqua:
                dark
            default:
                NSColor()
            }
        }
    }
}
