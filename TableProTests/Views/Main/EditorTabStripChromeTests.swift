//
//  EditorTabStripChromeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

/// The strip sits in the content view over flat window background, so anything it fills behind the
/// tabs is a second surface the rest of the window does not have. Sampling is symmetric about the
/// band's centre so the assertions hold whichever way the hosting view flips its coordinates.
@Suite("Editor tab strip chrome")
@MainActor
struct EditorTabStripChromeTests {
    private static let width: CGFloat = 600
    private static let margin: CGFloat = 20
    private static let bandHeight = EditorTabStripLayout.trackHeight + EditorTabStripLayout.stripInset * 2

    private static var totalHeight: CGFloat { bandHeight + margin * 2 }

    /// Two points inside the track's own padding, above and below every tab, where only a track
    /// fill could ever paint.
    private static var trackRows: [CGFloat] {
        let trackTop = margin + EditorTabStripLayout.stripInset
        let trackBottom = trackTop + EditorTabStripLayout.trackHeight
        return [trackTop + 1, trackBottom - 1]
    }

    /// The same distance outside the band on each side, which is untouched window background.
    private static var backdropRows: [CGFloat] { [margin / 2, totalHeight - margin / 2] }

    private static let sampleColumns: [CGFloat] = [200, 300, 400]

    private func makeHost(appearance: NSAppearance.Name) -> NSView {
        let manager = QueryTabManager()
        manager.tabs = ["Album", "Artist", "Customer"].map { QueryTab(title: $0) }
        manager.selectedTabId = manager.tabs.first?.id

        let strip = EditorTabStrip(
            tabManager: manager,
            onClose: { _ in },
            onCloseOthers: { _ in },
            onCloseAll: {},
            onNewTab: {}
        )

        let content = ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.margin)
                strip
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

    @Test("The strip paints no track behind the tabs", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func trackIsUnpainted(appearance: NSAppearance.Name) {
        let host = makeHost(appearance: appearance)

        let backdrop = brightness(of: host, rows: Self.backdropRows, columns: Self.sampleColumns)
        let track = brightness(of: host, rows: Self.trackRows, columns: Self.sampleColumns)

        guard let reference = backdrop.first else {
            Issue.record("The strip did not rasterise")
            return
        }
        /// Anchored to the colour the band is supposed to be, so an all-black or otherwise empty
        /// bitmap cannot satisfy the comparisons below by agreeing with itself.
        #expect(abs(reference - windowBackgroundBrightness(for: appearance)) < 0.01)

        #expect(track.count == backdrop.count)
        #expect(backdrop.allSatisfy { abs($0 - reference) < 0.005 })
        #expect(track.allSatisfy { abs($0 - reference) < 0.005 })

        /// Without this, a strip that drew nothing at all would satisfy every assertion above.
        let bandCentre = Self.margin + Self.bandHeight / 2
        let ink = brightness(of: host, rows: [bandCentre], columns: Array(stride(from: 20, to: Self.width - 20, by: 4)))
        #expect(ink.contains { abs($0 - reference) > 0.01 })
    }
}
