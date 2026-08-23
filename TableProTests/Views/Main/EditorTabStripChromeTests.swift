//
//  EditorTabStripChromeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

/// What this suite can and cannot see is decided by Liquid Glass, not by the strip.
///
/// The track and the selected tab are both `glassEffect` surfaces, and glass is composited by the
/// window server rather than drawn into a view's own context: `cacheDisplay`, `layer.render` and
/// `dataWithPDF` all come back with zero non-transparent pixels for it, measured. So no assertion
/// here can describe the track's material. That is checked by comparing the running app against
/// the system's own tab bar, which is where the geometry in `EditorTabStripLayout` came from too.
///
/// What rasterises is everything drawn *on* the glass: the titles, the separators and the close
/// button. That is the half worth guarding anyway, because it is the half that broke. A
/// `GlassEffectContainer` raises the glass it holds above the container's other content, so the
/// first two attempts at this strip painted the glass over the selected tab's own title and then
/// over its close button, leaving a tab whose label was dimmer than its neighbours' and which had
/// no visible way to close it. Both tests below fail if that returns.
@Suite("Editor tab strip chrome")
@MainActor
struct EditorTabStripChromeTests {
    private static let width: CGFloat = 600
    private static let margin: CGFloat = 20
    private static let tabCount = 3
    private static let bandHeight = EditorTabStripLayout.bandHeight

    private static var totalHeight: CGFloat { bandHeight + margin * 2 }

    /// The row the titles and the close button sit on.
    private static var contentRows: [CGFloat] {
        let centre = margin + EditorTabStripLayout.trackHeight / 2
        return Array(stride(from: centre - 4, through: centre + 4, by: 1))
    }

    private static var backdropRows: [CGFloat] { [margin / 2, totalHeight - margin / 2] }

    private static var trackWidth: CGFloat {
        width - EditorTabStripLayout.stripInset * 2
            - EditorTabStripLayout.newTabButtonSize - EditorTabStripLayout.trackSpacing
    }

    private static var tabWidth: CGFloat {
        EditorTabStripLayout.tabWidth(forTrack: trackWidth, count: tabCount)
    }

    private static func tabOrigin(_ index: Int) -> CGFloat {
        EditorTabStripLayout.stripInset + EditorTabStripLayout.trackPadding + tabWidth * CGFloat(index)
    }

    /// The close button sits `accessoryInset` in from its tab's leading edge and is
    /// `accessoryWidth` across.
    private static func closeGlyphColumns(ofTabAt index: Int) -> [CGFloat] {
        let leading = tabOrigin(index) + EditorTabStripLayout.accessoryInset
        return Array(stride(from: leading, to: leading + EditorTabStripLayout.accessoryWidth, by: 1))
    }

    /// The middle of a tab, where its title is centred and no accessory reaches.
    private static func titleColumns(ofTabAt index: Int) -> [CGFloat] {
        let centre = tabOrigin(index) + tabWidth / 2
        return Array(stride(from: centre - 40, through: centre + 40, by: 2))
    }

    private func makeHost(appearance: NSAppearance.Name) -> NSView {
        let manager = QueryTabManager()
        manager.tabs = ["Album", "Artist", "Customer"].map { QueryTab(title: $0) }
        manager.selectedTabId = manager.tabs.first?.id

        let strip = EditorTabStrip(
            tabManager: manager,
            containerTarget: nil,
            onClose: { _ in },
            onCloseOthers: { _ in },
            onCloseAll: {},
            onNewTab: {}
        )

        let content = ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.margin)
                strip.frame(height: Self.bandHeight)
                Color.clear.frame(height: Self.margin)
            }
        }
        .frame(width: Self.width, height: Self.totalHeight)

        let host = NSHostingView(rootView: AnyView(content))
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.totalHeight)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        settle(window)
        return host
    }

    /// Laying the hosting view's own subtree out is enough here. Spinning the run loop instead
    /// would let another suite's queued main-actor work run in the middle of this one.
    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The colour the band is supposed to sit on, resolved independently of the bitmap. Every
    /// comparison below is anchored to it so that an empty or all-black rasterisation cannot
    /// satisfy the assertions by agreeing with itself.
    private func windowBackgroundBrightness(for appearance: NSAppearance.Name) -> CGFloat {
        var brightness: CGFloat = 0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            brightness = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        return brightness
    }

    private func brightness(of view: NSView, rows: [CGFloat], columns: [CGFloat]) -> [CGFloat] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        return rows.flatMap { row in
            columns.compactMap { column -> CGFloat? in
                let x = min(rep.pixelsWide - 1, Int(column * scale))
                let y = min(rep.pixelsHigh - 1, Int(row * scale))
                return rep.colorAt(x: x, y: y)?.brightnessComponent
            }
        }
    }

    /// Ink, as distance from the surface the glyphs are drawn on, so the same assertion holds in
    /// light where a label is darker than its background and in dark where it is lighter.
    private func inkContrast(of view: NSView, columns: [CGFloat]) -> CGFloat {
        let samples = brightness(of: view, rows: Self.contentRows, columns: columns)
        guard let low = samples.min(), let high = samples.max() else { return 0 }
        return high - low
    }

    @Test(
        "The selected tab's close button is drawn on its glass, not buried under it",
        arguments: [NSAppearance.Name.aqua, .darkAqua]
    )
    func selectedTabShowsItsCloseButton(appearance: NSAppearance.Name) {
        let host = makeHost(appearance: appearance)

        let onSelected = inkContrast(of: host, columns: Self.closeGlyphColumns(ofTabAt: 0))
        let onPlain = inkContrast(of: host, columns: Self.closeGlyphColumns(ofTabAt: 2))

        /// A drawn glyph puts light pixels next to dark ones inside a box that is otherwise one
        /// flat surface, so the spread is what proves it is there.
        #expect(onSelected > 0.1)

        /// The same box on a tab that is neither selected nor hovered carries no button, which is
        /// what stops a stray highlight anywhere in the strip from satisfying the check above.
        #expect(onPlain < 0.05)
    }

    /// The selected title is `labelColor` and the rest are `secondaryLabelColor`, so the selected
    /// one always stands further from whatever it is drawn on. It went the other way when the
    /// glass was painting over it, and the difference was large: the selected title measured a
    /// peak of 121 against 166 for its neighbours, on a surface of 86.
    @Test(
        "The selected tab's title reads stronger than its neighbours, not weaker",
        arguments: [NSAppearance.Name.aqua, .darkAqua]
    )
    func selectedTitleOutreadsTheOthers(appearance: NSAppearance.Name) {
        let host = makeHost(appearance: appearance)

        let selected = inkContrast(of: host, columns: Self.titleColumns(ofTabAt: 0))
        let unselected = inkContrast(of: host, columns: Self.titleColumns(ofTabAt: 2))

        #expect(selected > 0.1)
        #expect(unselected > 0.1)
        #expect(selected > unselected)
    }

    /// The band is 36pt and only its top 28 carry the track, so the strip must not paint the
    /// clearance the system leaves between the tab bar and the content below it.
    @Test("The band leaves its bottom clearance to the window", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func clearanceBelowTrackIsUnpainted(appearance: NSAppearance.Name) {
        let host = makeHost(appearance: appearance)

        let clearanceRow = Self.margin + EditorTabStripLayout.trackHeight
            + EditorTabStripLayout.bandBottomClearance / 2
        let columns = Self.titleColumns(ofTabAt: 1)

        let backdrop = brightness(of: host, rows: Self.backdropRows, columns: columns)
        let clearance = brightness(of: host, rows: [clearanceRow], columns: columns)

        guard let reference = backdrop.first else {
            Issue.record("The strip did not rasterise")
            return
        }
        /// Without this the two comparisons below would hold on a bitmap that rendered nothing at
        /// all, because both sides would be reading the same blank.
        #expect(abs(reference - windowBackgroundBrightness(for: appearance)) < 0.01)
        #expect(!clearance.isEmpty)
        #expect(clearance.allSatisfy { abs($0 - reference) < 0.005 })
    }
}
