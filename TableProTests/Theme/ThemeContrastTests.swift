//
//  ThemeContrastTests.swift
//  TableProTests
//
//  Sidebar sections, status lines and empty states put the system's secondary label on the window
//  background, so a bundled theme that sets one has to keep that label legible. The system's own
//  secondary label sits under 4.5:1 on every light window (3.95:1 on white), so a light theme is held
//  to the WCAG floor for secondary text, 3:1.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeContrastTests {
    private static func bundledThemes() throws -> [ThemeDefinition] {
        try (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(ThemeDefinition.builtInPrefix) }
            .map { try ThemeFileFormat.decode(try Data(contentsOf: $0)) }
    }

    private static let lightSecondaryContrast: CGFloat = 3

    /// `secondaryLabelColor` is translucent, so what the eye reads is the label over the fill.
    private static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let alpha = foreground.alphaComponent
        return NSColor(
            srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let first = lhs.relativeLuminance
        let second = rhs.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    @Test("The secondary label stays legible on every bundled window background")
    func secondaryLabelOnWindowBackground() throws {
        let themed = try Self.bundledThemes().filter { $0.isOverridden(.windowBackdrop) }
        #expect(themed.count >= 2, "Expected Dracula and Nord to set a window background")

        for theme in themed {
            let appearance = try #require(NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua))
            var label: NSColor?
            var background: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                label = NSColor.secondaryLabelColor.usingColorSpace(.sRGB)
                background = theme.color(for: .windowBackdrop, in: appearance).usingColorSpace(.sRGB)
            }
            let secondary = try #require(label)
            let fill = try #require(background)
            let ratio = Self.contrast(Self.composite(secondary, over: fill), fill)
            let bar = theme.appearance == .dark ? Color.minimumLabelContrast : Self.lightSecondaryContrast

            #expect(ratio >= bar, "\(theme.id): \(ratio), bar \(bar)")
        }
    }
}
