//
//  EditorTabStripGlassGuardTests.swift
//  TableProTests
//
//  A source scan, because the thing it guards cannot be rasterised: a `glassEffect` renders in the
//  window server, and `cacheDisplay` returns an empty bitmap for the whole hosting view rather
//  than for the glass alone. The property is structural anyway, so a scan states it directly.
//

import Foundation
import Testing

@Suite("Editor tab strip glass")
struct EditorTabStripGlassGuardTests {
    /// The strip may carry exactly one Liquid Glass surface, and it is the new-tab button.
    ///
    /// The track and the selected tab were both glass, tinted apart, and the step between them
    /// turned out to be a function of the wallpaper behind the window: measured across twenty
    /// arrangements on macOS 27, every glass surface nested in, beside, or unioned with another
    /// rendered darker than its track in light appearance, and the shipped pair inverted again
    /// whenever the window lost key (#2439). Apple asks for the same shape in WWDC25 session 219,
    /// "avoid applying the material to both layers. Instead, use fills, transparency, and vibrancy
    /// for the top elements", and macOS 27's own `NSSegmentedControlRole.tabs` draws this control
    /// with opaque fills.
    @Test("Only the new-tab button is drawn in glass")
    func onlyTheNewTabButtonUsesGlass() throws {
        let source = try Self.stripSource()
        let lines = source.components(separatedBy: .newlines)
        let glassLines = lines.indices.filter { lines[$0].contains("glassEffect(") }

        #expect(
            glassLines.count == 1,
            """
            The editor tab strip may draw exactly one glass surface, the new-tab button. A track \
            or a selected tab drawn in glass takes its colour from whatever is behind the window, \
            so the selection stops meaning the same thing over every wallpaper: \
            \(glassLines.map { "line \($0 + 1)" })
            """
        )

        let owner = glassLines.first.map { index -> String in
            lines[...index].reversed().first { $0.contains("func ") } ?? ""
        }
        #expect(
            owner?.contains("newTabSurface") == true,
            "The strip's one glass surface must belong to newTabSurface, not \(owner ?? "nothing")"
        )
    }

    /// Fully rounded, because the system's own tab bar is. Its runtime view tree reports
    /// `cornerRadius = 12` on each 24pt tab, exactly half the height, and a corner fit of the 28pt
    /// track lands at 12 to 14pt. An earlier pass took the shallower `(height - 4) / 4` radius from
    /// an in-content `NSSegmentedControl`, which is a different control in a different place.
    @Test("The track and its tabs stay fully rounded")
    func surfacesAreFullyRounded() throws {
        let source = try Self.stripSource()
        let lines = source.components(separatedBy: .newlines)
        let shaped = lines.indices.filter {
            lines[$0].contains("RoundedRectangle(") || lines[$0].contains("cornerRadius:")
        }

        #expect(
            shaped.isEmpty,
            """
            The strip's surfaces take EditorTabStripLayout's capsule shapes, matching the system \
            tab bar's own half-height corner radius: \(shaped.map { "line \($0 + 1)" })
            """
        )
    }

    private static func stripSource(file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("CLAUDE.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let strip = directory
                    .appendingPathComponent("TablePro/Views/Main/EditorTabStrip.swift")
                return try String(contentsOf: strip, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw GlassGuardError.repoRootNotFound
    }

    private enum GlassGuardError: Error {
        case repoRootNotFound
    }
}
