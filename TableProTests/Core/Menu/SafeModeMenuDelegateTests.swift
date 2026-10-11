//
//  SafeModeMenuDelegateTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The Safe Mode list, which the Database menu's submenu and the toolbar control both open.
///
/// It used to list every level whatever held the connection, with nothing saying why a weaker one
/// changed nothing: Agent mode raised the floor to Alert silently, and a pick of Silent was stored
/// while the level on screen stayed put.
@MainActor
struct SafeModeMenuDelegateTests {
    private static let agentFloor = SafeModeFloor(level: .alert, reason: .agentMode)

    private static func levelItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.action == #selector(MainSplitViewController.setSafeModeLevel(_:)) }
    }

    @Test("Under a floor the list offers only the levels the floor allows")
    func listOffersOnlyAllowedLevels() {
        let menu = NSMenu()

        SafeModeMenuDelegate.populate(menu, with: SafeModeStatus(level: .alert, floor: Self.agentFloor))

        let offered = Self.levelItems(in: menu).compactMap { ($0.representedObject as? String).flatMap(SafeModeLevel.init) }
        #expect(offered == SafeModeFloor.levels(allowedBy: Self.agentFloor))
        #expect(!offered.contains(.silent))
    }

    @Test("The checkmark is on the level in force")
    func checkmarkFollowsTheLevelInForce() {
        let menu = NSMenu()

        SafeModeMenuDelegate.populate(menu, with: SafeModeStatus(level: .safeMode, floor: Self.agentFloor))

        let checked = Self.levelItems(in: menu).filter { $0.state == .on }
        #expect(checked.map(\.title) == [SafeModeLevel.safeMode.displayName])
    }

    /// The floor's reason used to be written in exactly one place, the connection form's Options
    /// pane, so a window in Agent mode never said why its level would not go down.
    @Test("The floor's reason closes the list as a disabled footnote", arguments: [
        SafeModeFloor(level: .alert, reason: .agentMode),
        SafeModeFloor(level: .readOnly, reason: .readOnlyEngine),
        SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile),
        SafeModeFloor(level: .safeMode, reason: .managedPolicy),
    ])
    func floorReasonIsTheFootnote(floor: SafeModeFloor) throws {
        let menu = NSMenu()

        SafeModeMenuDelegate.populate(menu, with: SafeModeStatus(level: floor.level, floor: floor))

        let footnote = try #require(menu.items.last)
        #expect(menu.items.dropLast().last?.isSeparatorItem == true)
        #expect(!footnote.isEnabled)
        #expect(footnote.action == nil)
        #expect(Self.unwrapped(footnote) == floor.explanation)
    }

    @Test("With no floor every level is listed and nothing is explained")
    func noFloorListsEveryLevel() {
        let menu = NSMenu()

        SafeModeMenuDelegate.populate(menu, with: SafeModeStatus(level: .silent, floor: nil))

        #expect(Self.levelItems(in: menu).count == SafeModeLevel.allCases.count)
        #expect(menu.items.count == SafeModeLevel.allCases.count)
    }

    /// A window with no session behind it has no level to check and no floor to explain, and the
    /// window's validation dims the entries.
    @Test("With no session every level is listed, unchecked")
    func noSessionListsEveryLevelUnchecked() {
        let menu = NSMenu()

        SafeModeMenuDelegate.populate(menu, with: nil)

        #expect(Self.levelItems(in: menu).count == SafeModeLevel.allCases.count)
        #expect(Self.levelItems(in: menu).allSatisfy { $0.state == .off })
    }

    @Test("Opening the list again rebuilds it rather than appending")
    func repopulatingReplacesTheItems() {
        let menu = NSMenu()
        let status = SafeModeStatus(level: .alert, floor: Self.agentFloor)

        SafeModeMenuDelegate.populate(menu, with: status)
        let first = menu.items.count
        SafeModeMenuDelegate.populate(menu, with: status)

        #expect(menu.items.count == first)
    }

    /// A menu item's plain title is one line however long it is, so the reason is broken into lines
    /// the width of the list rather than widening the list to fit one.
    @Test("The footnote wraps to the list's width instead of widening it")
    func footnoteWraps() throws {
        let explanation = SafeModeFloor(level: .readOnly, reason: .remoteDatabaseFile).explanation
        let item = MenuFootnote.item(explanation)
        let lines = try #require(item.attributedTitle?.string.components(separatedBy: "\n"))

        #expect(lines.count > 1)
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: MenuFootnote.font]).width
            #expect(width <= MenuFootnote.wrapWidth + 1, "\(line)")
        }
        #expect(Self.unwrapped(item) == explanation)
    }

    private static func unwrapped(_ item: NSMenuItem) -> String? {
        item.attributedTitle?.string.replacingOccurrences(of: "\n", with: " ")
    }
}
