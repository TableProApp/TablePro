//
//  EditorTabStripChromeTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@MainActor
struct EditorTabStripChromeTests {
    private static let width: CGFloat = 600
    private static let margin: CGFloat = 20
    private static let bandHeight = EditorTabStripLayout.bandHeight
    private static var totalHeight: CGFloat { bandHeight + margin * 2 }

    private static var trackRow: CGFloat { margin + EditorTabStripLayout.trackHeight / 2 }
    private static var contentRows: [CGFloat] { Array(stride(from: trackRow - 4, through: trackRow + 4, by: 1)) }
    private static var backdropRows: [CGFloat] { [margin / 2, totalHeight - margin / 2] }

    private static var viewportWidth: CGFloat {
        width - EditorTabStripLayout.stripInset * 2 - EditorTabStripLayout.newTabButtonSize
            - EditorTabStripLayout.trackSpacing - EditorTabStripLayout.trackPadding * 2
    }

    private static var tabWidth: CGFloat { viewportWidth / 3 }

    private static func tabOrigin(_ index: Int) -> CGFloat {
        EditorTabStripLayout.stripInset + EditorTabStripLayout.trackPadding + tabWidth * CGFloat(index)
    }

    private static func surfaceColumn(ofTabAt index: Int) -> CGFloat { tabOrigin(index) + 14 }

    private static func titleColumns(ofTabAt index: Int) -> [CGFloat] {
        let centre = tabOrigin(index) + tabWidth / 2
        return Array(stride(from: centre - 30, through: centre + 30, by: 2))
    }

    private func makeHost(appearance: NSAppearance.Name, isActive: Bool = false) -> (NSView, EditorTabStripView) {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.totalHeight)
        let host = NSView(frame: frame)
        let strip = EditorTabStripView(frame: NSRect(
            x: 0,
            y: Self.margin,
            width: Self.width,
            height: Self.bandHeight
        ))
        host.addSubview(strip)

        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host

        strip.commands = .stub()
        strip.apply(EditorTabItem.samples(titles: ["Album", "Artist", "Customer"]))
        strip.items.forEach { strip.itemView(for: $0.id)?.isWindowActive = isActive }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return (host, strip)
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

    private func inkContrast(of view: NSView, columns: [CGFloat]) -> CGFloat {
        let samples = brightness(of: view, rows: Self.contentRows, columns: columns)
        guard let low = samples.min(), let high = samples.max() else { return 0 }
        return high - low
    }

    @Test("The selected tab shows its close button only under the pointer, as the system bar does")
    func closeButtonFollowsThePointer() throws {
        let (_, strip) = makeHost(appearance: .aqua, isActive: true)
        let selected = try #require(strip.itemView(for: strip.items[0].id))

        #expect(selected.closeButton.isHidden)

        selected.isHovered = true
        #expect(!selected.closeButton.isHidden)

        selected.isHovered = false
        #expect(selected.closeButton.isHidden)
    }

    @Test("A background window shows no close button under the pointer")
    func backgroundWindowHidesTheCloseButton() throws {
        let (_, strip) = makeHost(appearance: .aqua, isActive: false)
        let selected = try #require(strip.itemView(for: strip.items[0].id))

        selected.isHovered = true

        #expect(selected.closeButton.isHidden)
    }

    @Test("The selected tab's title reads stronger than its neighbours", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func selectedTitleOutreadsTheOthers(appearance: NSAppearance.Name) {
        let (host, _) = makeHost(appearance: appearance)

        let selected = inkContrast(of: host, columns: Self.titleColumns(ofTabAt: 0))
        let unselected = inkContrast(of: host, columns: Self.titleColumns(ofTabAt: 2))

        #expect(selected > 0.1)
        #expect(unselected > 0.1)
        #expect(selected > unselected)
    }

    @Test(
        "The selected tab's surface stands clear of the track in either window state",
        arguments: [NSAppearance.Name.aqua, .darkAqua], [true, false]
    )
    func selectedSurfaceStandsClearOfTheTrack(appearance: NSAppearance.Name, isActive: Bool) throws {
        let (host, _) = makeHost(appearance: appearance, isActive: isActive)

        let selected = brightness(of: host, rows: [Self.trackRow], columns: [Self.surfaceColumn(ofTabAt: 0)])
        let plain = brightness(of: host, rows: [Self.trackRow], columns: [Self.surfaceColumn(ofTabAt: 2)])

        let selectedTone = try #require(selected.first)
        let plainTone = try #require(plain.first)
        #expect(abs(selectedTone - plainTone) > 0.05)
    }

    @Test("The band leaves its bottom clearance to the window", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func clearanceBelowTrackIsUnpainted(appearance: NSAppearance.Name) throws {
        let (host, _) = makeHost(appearance: appearance)
        let clearanceRow = Self.margin + EditorTabStripLayout.trackHeight
            + (EditorTabStripLayout.bandHeight - EditorTabStripLayout.trackHeight) / 2
        let columns = Self.titleColumns(ofTabAt: 1)

        let backdrop = brightness(of: host, rows: Self.backdropRows, columns: columns)
        let clearance = brightness(of: host, rows: [clearanceRow], columns: columns)

        let reference = try #require(backdrop.first)
        #expect(!clearance.isEmpty)
        #expect(clearance.allSatisfy { abs($0 - reference) < 0.005 })
    }
}
