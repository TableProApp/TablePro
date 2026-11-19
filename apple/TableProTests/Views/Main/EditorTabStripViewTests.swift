//
//  EditorTabStripViewTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct EditorTabStripViewTests {
    private static let size = NSSize(width: 652, height: EditorTabStripLayout.bandHeight)

    private func makeStrip(
        titles: [String] = ["Album", "Artist", "Customer"],
        width: CGFloat = Self.size.width,
        recorder: EditorTabCommandRecorder = EditorTabCommandRecorder()
    ) -> (EditorTabStripView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: Self.size.height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let strip = EditorTabStripView(frame: NSRect(origin: .zero, size: window.frame.size))
        strip.commands = .stub(recorder: recorder)
        window.contentView = strip
        strip.apply(EditorTabItem.samples(titles: titles))
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    private func views(of strip: EditorTabStripView) -> [EditorTabItemView] {
        strip.items.compactMap { strip.itemView(for: $0.id) }
    }

    @Test("Every item gets a view, laid out in order across the track")
    func viewsFollowTheItems() {
        let (strip, window) = makeStrip()
        defer { window.orderOut(nil) }

        let minXs = views(of: strip).map(\.frame.minX)
        #expect(minXs.count == 3)
        #expect(minXs == minXs.sorted())
        #expect(views(of: strip).allSatisfy { $0.frame.width == strip.run.tabWidth })
    }

    @Test("A band too narrow for the track keeps finite geometry", arguments: [0, 1, 40] as [CGFloat])
    func narrowBandKeepsFiniteGeometry(width: CGFloat) {
        let (strip, window) = makeStrip(width: max(width, 1))
        defer { window.orderOut(nil) }

        strip.setFrameSize(NSSize(width: width, height: Self.size.height))
        strip.layoutSubtreeIfNeeded()

        #expect(strip.scrollView.frame.minX.isFinite)
        #expect(strip.scrollView.frame.minY.isFinite)
        #expect(strip.scrollView.frame.width == 0)
        #expect(strip.items.allSatisfy { strip.itemView(for: $0.id)?.frame.minX.isFinite == true })
    }

    @Test("A title with room is drawn whole")
    func titleWithRoomIsNotTruncated() throws {
        let (strip, window) = makeStrip(titles: ["beta_invites", "beta_testers", "license_jobs", "licenses"], width: 1_200)
        defer { window.orderOut(nil) }

        for item in strip.items {
            let view = try #require(strip.itemView(for: item.id))
            view.layoutSubtreeIfNeeded()
            let needed = ceil(view.titleField.attributedStringValue.size().width)
            #expect(view.titleField.frame.width >= needed, "\(item.title) got \(view.titleField.frame.width) of \(needed)")
        }
    }

    @Test("A closed tab's view leaves and the others take its share")
    func closedTabLeaves() {
        let (strip, window) = makeStrip()
        defer { window.orderOut(nil) }
        let closed = strip.items[1].id
        let width = strip.run.tabWidth

        strip.apply(strip.items.filter { $0.id != closed })

        #expect(strip.itemView(for: closed) == nil)
        #expect(strip.run.tabWidth > width)
    }

    @Test("A title change reaches the existing view")
    func updatedItemKeepsItsView() {
        let (strip, window) = makeStrip()
        defer { window.orderOut(nil) }
        let id = strip.items[0].id
        let view = strip.itemView(for: id)

        strip.apply([.sample(id: id, title: "Renamed", isSelected: true)] + strip.items.dropFirst())

        #expect(strip.itemView(for: id) === view)
        #expect(view?.item.title == "Renamed")
    }

    @Test("Selecting a tab past the edge scrolls it to full width")
    func selectionIsRevealed() {
        let titles = (0 ..< 14).map { "table_\($0)" }
        let (strip, window) = makeStrip(titles: titles)
        defer { window.orderOut(nil) }

        let last = EditorTabItem.sample(
            id: strip.items[13].id,
            title: "table_13",
            isSelected: true,
            position: 14,
            count: 14
        )
        var items = strip.items.map {
            EditorTabItem.sample(id: $0.id, title: $0.title, position: $0.position, count: $0.count)
        }
        items[13] = last
        strip.apply(items)
        strip.reveal(last.id, animated: false)
        strip.layoutSubtreeIfNeeded()

        #expect(strip.scrollView.contentView.bounds.minX > 0)
        #expect(strip.itemView(for: last.id)?.frame.width == EditorTabStripLayout.minimumTabWidth)
    }

    @Test("A second click on the tab the first one activated keeps it open")
    func doubleClickKeepsTheTab() {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        let id = strip.items[1].id

        strip.activate(id, click: EditorTabClick(clickCount: 1, hasModifiers: false))
        strip.activate(id, click: EditorTabClick(clickCount: 2, hasModifiers: false))

        #expect(recorder.activated == [id, id])
        #expect(recorder.kept == [id])
    }

    @Test("A double-click straddling two tabs keeps neither")
    func doubleClickAcrossTabsKeepsNothing() {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }

        strip.activate(strip.items[0].id, click: EditorTabClick(clickCount: 1, hasModifiers: false))
        strip.activate(strip.items[1].id, click: EditorTabClick(clickCount: 2, hasModifiers: false))

        #expect(recorder.kept.isEmpty)
    }

    @Test("Only a tab released on empty space opens a window")
    func dragEndingOpensAWindowOnlyOnARelease() {
        func opens(
            operation: NSDragOperation = [],
            cancelled: Bool = false,
            overStrip: Bool = false,
            canTearOff: Bool = true
        ) -> Bool {
            EditorTabDragEnding.opensNewWindow(
                operation: operation,
                wasCancelled: cancelled,
                isOverTabStrip: overStrip,
                canTearOff: canTearOff
            )
        }

        #expect(opens())
        #expect(!opens(operation: .move))
        #expect(!opens(cancelled: true))
        #expect(!opens(overStrip: true))
        #expect(!opens(canTearOff: false))
    }

    @Test("The new tab button runs the command")
    func newTabButton() {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }

        strip.newTabButton.performClick(nil)

        #expect(recorder.newTabCount == 1)
    }

    @Test("The strip is a tab group and each tab a selected or unselected tab button")
    func accessibilityRoles() throws {
        let (strip, window) = makeStrip()
        defer { window.orderOut(nil) }
        let selected = try #require(strip.itemView(for: strip.items[0].id))
        let other = try #require(strip.itemView(for: strip.items[1].id))

        #expect(strip.accessibilityRole() == .tabGroup)
        #expect(strip.accessibilityTabs()?.count == 3)
        #expect(selected.accessibilityRole() == .radioButton)
        #expect(selected.accessibilitySubrole() == .tabButtonSubrole)
        #expect(selected.accessibilityIdentifier() == "editor-tab")
        #expect(selected.accessibilityLabel() == "Album")
        #expect(selected.isAccessibilitySelected())
        #expect(selected.accessibilityValue() as? NSNumber == 1)
        #expect(!other.isAccessibilitySelected())
        #expect(other.accessibilityValue() as? NSNumber == 0)
    }

    @Test("Pressing a tab through accessibility selects it")
    func accessibilityPress() throws {
        let recorder = EditorTabCommandRecorder()
        let (strip, window) = makeStrip(recorder: recorder)
        defer { window.orderOut(nil) }
        let id = strip.items[2].id

        #expect(try #require(strip.itemView(for: id)).accessibilityPerformPress())
        #expect(recorder.activated == [id])
    }

    @Test("The menu's enabled commands are offered to assistive technology")
    func accessibilityActionsFollowTheMenu() throws {
        let (strip, window) = makeStrip()
        defer { window.orderOut(nil) }
        let view = try #require(strip.itemView(for: strip.items[0].id))

        let names = view.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(names.contains(String(localized: "Close Tab")))
        #expect(names.contains(String(localized: "Pin Tab")))
        #expect(!names.contains(String(localized: "Keep Open")))
    }
}
