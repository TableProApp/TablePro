//
//  SidebarScopeControlTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// The Tables and Favorites choice, in its own row at the top of the sidebar.
@Suite("Sidebar scope control", .serialized)
@MainActor
struct SidebarScopeControlTests {
    /// The sidebar's own minimum, and the insets the row is laid out with.
    private static let sidebarMinimum = MainSplitViewController.sidebarMinThickness
    private static let rowInset: CGFloat = 10

    @Test("Two worded segments, one of which is selected at a time")
    func shape() {
        let control = SidebarScopeControl()

        #expect(control.segmentCount == 2)
        #expect(control.trackingMode == .selectOne)
        #expect(control.segmentDistribution == .fillEqually)
        #expect(control.label(forSegment: 0) == String(localized: "Tables"))
        #expect(control.label(forSegment: 1) == String(localized: "Favorites"))
    }

    /// The toolbar version was measured announcing its SF Symbol names, "List" and "favorite". A
    /// worded segment publishes its own label, measured on macOS 27 as a radio group of two radio
    /// buttons under the control.
    @Test("Each segment names itself for assistive clients")
    func segmentsAreNamed() throws {
        let control = SidebarScopeControl()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.sidebarMinimum, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(control)
        control.frame = NSRect(x: Self.rowInset, y: 40, width: Self.sidebarMinimum - 2 * Self.rowInset, height: 24)
        defer { control.removeFromSuperview() }

        var labels: [String] = []
        func collect(_ element: Any, depth: Int) {
            guard depth < 4, let object = element as? NSObject else { return }
            if (object.value(forKey: "accessibilityRole") as? String) == NSAccessibility.Role.radioButton.rawValue,
               let label = object.value(forKey: "accessibilityLabel") as? String {
                labels.append(label)
            }
            for child in (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
                collect(child, depth: depth + 1)
            }
        }
        collect(control, depth: 0)

        #expect(labels == [String(localized: "Tables"), String(localized: "Favorites")])
    }

    @Test("The selected tab reads back, and nil selects nothing")
    func selectedTabRoundTrips() {
        let control = SidebarScopeControl()

        control.selectedTab = .favorites
        #expect(control.selectedSegment == 1)
        #expect(control.selectedTab == .favorites)

        control.selectedTab = nil
        #expect(control.selectedSegment == -1)
        #expect(control.selectedTab == nil)

        control.selectedTab = .tables
        #expect(control.selectedTab == .tables)
    }

    /// Measured by laying the real sidebar chrome out at the sidebar's minimum width: the control
    /// takes the row's width and never less than it asks for, so no segment is clipped.
    @Test("The control fits the sidebar at its minimum width")
    func fitsAtTheSidebarMinimum() throws {
        let container = SidebarContainerViewController()
        container.view.frame = NSRect(x: 0, y: 0, width: Self.sidebarMinimum, height: 600)
        container.view.layoutSubtreeIfNeeded()
        let control = try #require(container.view.subviews.compactMap { $0 as? SidebarScopeControl }.first)

        #expect(control.frame.width >= control.intrinsicContentSize.width)
        #expect(control.frame.minX >= Self.rowInset - 0.5)
        #expect(control.frame.maxX <= Self.sidebarMinimum - Self.rowInset + 0.5)
    }

    /// The same measurement for every language the app ships, from the catalog's own translations:
    /// a label that only fits in English is a label clipped in Turkish.
    @Test("Both labels fit at the sidebar minimum in every shipped language")
    func fitsInEveryLanguage() throws {
        let available = Self.sidebarMinimum - 2 * Self.rowInset
        for (language, pair) in try Self.shippedLabels() {
            let control = SidebarScopeControl()
            control.setLabel(pair.tables, forSegment: 0)
            control.setLabel(pair.favorites, forSegment: 1)
            #expect(
                control.intrinsicContentSize.width <= available,
                "\(language) needs \(control.intrinsicContentSize.width)pt of \(available)pt"
            )
        }
    }

    /// View > Show Tables and Show Favorites write the connection's state, and the control reads
    /// it back, so all three stay in step whichever route moved them.
    @Test("The control follows the sidebar state in both directions")
    func selectionFollowsTheState() async throws {
        let connectionId = UUID()
        defer { SharedSidebarState.removeConnection(connectionId) }
        let state = SharedSidebarState.forConnection(connectionId)
        state.selectedSidebarTab = .tables

        let container = SidebarContainerViewController()
        container.view.frame = NSRect(x: 0, y: 0, width: Self.sidebarMinimum, height: 600)
        var chosen: [SidebarTab] = []
        container.onScopeSelection = { chosen.append($0) }

        container.updateSidebarState(state)
        #expect(container.selectedScope == .tables)
        #expect(container.isScopeEnabled)

        state.selectedSidebarTab = .favorites
        #expect(await Self.waitFor { container.selectedScope == .favorites })

        let control = try #require(container.view.subviews.compactMap { $0 as? SidebarScopeControl }.first)
        control.selectedTab = .tables
        control.sendAction(control.action, to: control.target)
        #expect(chosen == [.tables])

        container.updateSidebarState(nil)
        #expect(container.selectedScope == nil)
        #expect(!container.isScopeEnabled)
    }

    /// Measured on macOS 27, a click on the segment already selected sends the action again. The
    /// command behind it collapses the sidebar on a second press of the list it shows, so from a
    /// control inside the sidebar that press is dropped rather than forwarded.
    @Test("Pressing the selected segment again does nothing")
    func reselectingIsNotForwarded() throws {
        let connectionId = UUID()
        defer { SharedSidebarState.removeConnection(connectionId) }
        let state = SharedSidebarState.forConnection(connectionId)
        state.selectedSidebarTab = .favorites

        let container = SidebarContainerViewController()
        container.view.frame = NSRect(x: 0, y: 0, width: Self.sidebarMinimum, height: 600)
        var chosen: [SidebarTab] = []
        container.onScopeSelection = { chosen.append($0) }
        container.updateSidebarState(state)
        defer { container.updateSidebarState(nil) }

        let control = try #require(container.view.subviews.compactMap { $0 as? SidebarScopeControl }.first)
        #expect(control.selectedTab == .favorites)
        control.sendAction(control.action, to: control.target)
        #expect(chosen.isEmpty)
    }

    /// Agent mode draws its session rail where the object list goes, so the scope and the filter
    /// both stand down, and the list takes their height rather than sitting under an empty band.
    @Test("Agent mode hides the scope row and the filter row, and the list takes their height")
    func agentModeHidesTheChrome() throws {
        let container = SidebarContainerViewController()
        container.view.frame = NSRect(x: 0, y: 0, width: Self.sidebarMinimum, height: 600)
        container.view.layoutSubtreeIfNeeded()
        let list = try #require(container.children.first?.view)
        let browsingTop = list.frame.maxY

        container.setChromeHidden(true)
        container.view.layoutSubtreeIfNeeded()
        let control = try #require(container.view.subviews.compactMap { $0 as? SidebarScopeControl }.first)
        let filter = try #require(container.view.subviews.compactMap { $0 as? NSStackView }.first)

        #expect(container.isChromeHidden)
        #expect(control.isHidden)
        #expect(filter.isHidden)
        #expect(list.frame.maxY > browsingTop, "The list stayed under the hidden rows")

        container.setChromeHidden(false)
        container.view.layoutSubtreeIfNeeded()
        #expect(!control.isHidden)
        #expect(!filter.isHidden)
        #expect(abs(list.frame.maxY - browsingTop) < 0.5)
    }

    /// The state reaches the control through a run-loop hop and then a main-actor job, so the test
    /// has to give the main thread back rather than spin it: a run loop spun inside this test runs
    /// no main-actor job, measured, because the test is one. Bounded by a count of short sleeps.
    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The two labels in every language the app catalog carries, English included.
    private static func shippedLabels() throws -> [(String, (tables: String, favorites: String))] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { directory.deleteLastPathComponent() }
        let url = directory.appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])

        func translations(of key: String) -> [String: String] {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            var values = ["en": key]
            for (language, localization) in localizations {
                let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
                if let value = unit?["value"] as? String { values[language] = value }
            }
            return values
        }

        let tables = translations(of: "Tables")
        let favorites = translations(of: "Favorites")
        #expect(tables.count > 1, "No translations found; the measurement would be English only")
        return tables.keys.sorted().compactMap { language in
            guard let table = tables[language], let favorite = favorites[language] else { return nil }
            return (language, (table, favorite))
        }
    }
}
