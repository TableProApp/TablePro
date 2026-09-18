//
//  ConnectionIdentityColorTests.swift
//  TableProTests
//
//  A connection answers two colour questions that used to share one property: which engine is this
//  (the brand colour, on the glyph) and which connection is this (the user's pick, on its own
//  surface). Collapsing them spent the pick recolouring an already-branded glyph, so the only
//  visible change was a hue shift on a 14pt icon (#2398).
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@Suite("Connection identity colour")
@MainActor
struct ConnectionIdentityColorTests {
    private static let appearances: [NSAppearance.Name] = [
        .aqua,
        .darkAqua,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
    ]

    private static let assignableColors = ConnectionColor.allCases.filter { !$0.isDefault }

    private func contrast(of fill: Color) -> CGFloat {
        let foreground = NSColor(Color.legibleForeground(on: fill)).relativeLuminance
        let background = NSColor(fill).relativeLuminance
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }

    private func connection(colored color: ConnectionColor) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Production")
        connection.color = color
        return connection
    }

    // MARK: - The two colours never substitute for each other

    @Test("A connection with no colour reports no identity colour")
    func uncolouredConnectionHasNoIdentity() {
        #expect(connection(colored: .none).identityColor == nil)
    }

    @Test("A coloured connection reports the colour the user picked")
    func colouredConnectionReportsThePick() {
        for color in Self.assignableColors {
            #expect(connection(colored: color).identityColor == color)
        }
    }

    /// The regression this whole change exists to prevent: the brand colour must not move when the
    /// user picks a colour, because the glyph that wears it identifies the engine on every
    /// connection and cannot also mean something per-connection.
    @Test("The brand colour is the engine's on every connection, coloured or not")
    func brandColourIgnoresTheUserPick() {
        let uncoloured = connection(colored: .none)
        for color in Self.assignableColors {
            #expect(connection(colored: color).brandColor == uncoloured.brandColor)
        }
    }

    // MARK: - The palette entry that means "no colour" is never a paintable colour

    /// `ConnectionColor.color` returns `.clear` for `.none`, and a caller that fills with it paints
    /// a transparent hole where the cue should be. Both accessors return `nil` instead so the type
    /// stops the mistake rather than a guard at each call site. The history drawer and the compare
    /// status strip both shipped that hole.
    @Test("Neither accessor hands back a paintable colour for the uncoloured entry")
    func uncolouredEntryHasNoPaintableColour() {
        #expect(ConnectionColor.none.indicatorColor == nil)
        #expect(ConnectionColor.none.labelledFill == nil)
    }

    @Test("Every assignable colour has both an indicator and a fill")
    func assignableColorsHaveBoth() {
        for color in Self.assignableColors {
            #expect(color.indicatorColor != nil, "\(color.rawValue) has no indicator colour")
            #expect(color.labelledFill != nil, "\(color.rawValue) has no labelled fill")
        }
    }

    @Test("The indicator keeps the palette hue untouched")
    func indicatorIsTheRawHue() {
        for color in Self.assignableColors {
            #expect(color.indicatorColor == color.color)
        }
    }

    // MARK: - Contrast

    /// The toolbar puts a 13pt `.callout` name on this fill and the workspace rail puts its label
    /// on it, so WCAG 2.2 asks 4.5:1 rather than the 3:1 that covers an icon or a border.
    /// `LegibleForegroundTests` holds `color` itself at 3:1, which is the right bar for a dot or a
    /// glyph tint; this is the bar for a fill that carries text.
    @Test("Every labelled fill clears 4.5:1 against its own label in every appearance")
    func labelledFillsClearTextContrast() {
        for name in Self.appearances {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for color in Self.assignableColors {
                    guard let fill = color.labelledFill else {
                        Issue.record("\(color.rawValue) has no labelled fill")
                        continue
                    }
                    #expect(
                        contrast(of: fill) >= Color.minimumLabelContrast,
                        "\(color.rawValue) reaches only \(contrast(of: fill)) in \(name.rawValue)"
                    )
                }
            }
        }
    }

    /// Measured, orange, yellow and green already clear 4.5:1 with a black label, so tuning must
    /// leave them exactly where they are. A tuner that dimmed every hue would make the palette
    /// duller for no contrast gained, which is the objection this design had to answer.
    @Test("A fill that already clears the bar is returned unchanged")
    func alreadyLegibleFillsAreUntouched() {
        for name in Self.appearances {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for color in Self.assignableColors where NSColor(color.color).contrastWithDerivedLabel >= Color
                    .minimumLabelContrast {
                    #expect(
                        Self.resolvesAlike(color.labelledFill, color.color),
                        "\(color.rawValue) was dimmed in \(name.rawValue) despite already clearing the bar"
                    )
                }
            }
        }
    }

    /// `Color` compares by how it was built, not by what it resolves to, so a system colour and the
    /// same colour round-tripped through `NSColor` are never `==`. Measured: `Color.orange` and
    /// `Color(nsColor: NSColor(Color.orange))` compare unequal with identical sRGB components.
    private static func resolvesAlike(_ lhs: Color?, _ rhs: Color) -> Bool {
        guard let lhs,
              let left = NSColor(lhs).usingColorSpace(.sRGB),
              let right = NSColor(rhs).usingColorSpace(.sRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.0001
            && abs(left.greenComponent - right.greenComponent) < 0.0001
            && abs(left.blueComponent - right.blueComponent) < 0.0001
    }

    /// Tuning lowers brightness and nothing else, so the fill still reads as the colour the user
    /// picked from the swatch. Measured, the worst case keeps 83% of its brightness.
    @Test("Tuning holds the hue and only ever dims")
    func tuningHoldsHue() {
        for name in Self.appearances {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for color in Self.assignableColors {
                    guard let fillColor = color.labelledFill,
                          let base = NSColor(color.color).usingColorSpace(.sRGB),
                          let tuned = NSColor(fillColor).usingColorSpace(.sRGB) else {
                        Issue.record("\(color.rawValue) did not resolve in \(name.rawValue)")
                        continue
                    }

                    let before = Self.components(of: base)
                    let after = Self.components(of: tuned)

                    #expect(abs(after.hue - before.hue) < 0.001, "\(color.rawValue) shifted hue in \(name.rawValue)")
                    #expect(after.brightness <= before.brightness + 0.001, "\(color.rawValue) brightened")
                    #expect(after.alpha == 1, "\(color.rawValue) is not opaque")
                }
            }
        }
    }

    private static func components(of color: NSColor) -> (hue: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, brightness, alpha)
    }
}

/// `.toolbarBackground(_:for:)` styles a toolbar SwiftUI itself installs, and it reaches that
/// toolbar by flowing up to the root view of a `Window` scene. TablePro runs the AppKit lifecycle
/// with no SwiftUI scene at all and installs a real `NSToolbar` in `MainWindowToolbar`, so the
/// modifier has nothing to act on. It sat in the app unused for four months after the toolbar
/// migration removed its last call site, which made "raise the tint opacity" look like a one-line
/// fix for #2398 when it would have changed nothing on screen.
@Suite("Toolbar background modifier stays out of the app target")
struct ToolbarBackgroundGuardTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    @Test("No source file reaches for a SwiftUI toolbar background")
    func appTargetHasNoToolbarBackground() throws {
        let root = Self.repositoryRoot.appendingPathComponent("TablePro")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard source.contains(".toolbarBackground(") else { continue }
            offenders.append(url.lastPathComponent)
        }

        #expect(
            offenders.isEmpty,
            "These reach a SwiftUI toolbar the app does not have: \(offenders.sorted())"
        )
    }
}
