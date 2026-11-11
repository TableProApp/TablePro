//
//  ToolbarLabelsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// The Navigator Layout's labels under the toolbar's icons, written into the display mode once per
/// change of the setting, so a mode the user picks from the toolbar's own menu afterwards stays.
@MainActor
struct ToolbarLabelsTests {
    /// A toolbar in a window, on a private identifier that never autosaves: the test host shares the
    /// app's defaults, so a toolbar named like the app's own would carry its mode into the next launch.
    private static func owner(
        labelsOn: Bool,
        record: ToolbarLabelsRecord,
        mode: NSToolbar.DisplayMode = .iconOnly
    ) -> MainWindowToolbar {
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.labels.\(UUID().uuidString)")
        toolbar.autosavesConfiguration = false
        let owner = MainWindowToolbar(managedToolbar: toolbar)
        owner.isInWindow = { true }
        owner.labelsRecord = record
        owner.labelsEnabled = { labelsOn }
        toolbar.displayMode = mode
        return owner
    }

    @Test("Labels on puts a label under every icon, and off puts the icons back alone")
    func displayModeFollowsTheSetting() {
        #expect(MainWindowToolbar.displayMode(showsLabels: true) == .iconAndLabel)
        #expect(MainWindowToolbar.displayMode(showsLabels: false) == .iconOnly)
    }

    @Test("Turning labels on shows them once")
    func turningOnShowsLabels() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLabelsRecord(defaults: storage.defaults)
        let owner = Self.owner(labelsOn: true, record: record)

        owner.reconcileDisplayMode()

        #expect(owner.managedToolbar.displayMode == .iconAndLabel)
        #expect(record.isApplied)
    }

    /// The toolbar's own menu is where a person picks a mode, so the layout asks once and then
    /// leaves the choice alone, across later windows and launches too.
    @Test("A mode the user picks after the layout asked for labels stays")
    func theUsersLaterChoiceWins() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLabelsRecord(defaults: storage.defaults)
        let owner = Self.owner(labelsOn: true, record: record)
        owner.reconcileDisplayMode()

        owner.managedToolbar.displayMode = .iconOnly
        owner.reconcileDisplayMode()
        #expect(owner.managedToolbar.displayMode == .iconOnly)

        let later = Self.owner(labelsOn: true, record: record, mode: .labelOnly)
        later.reconcileDisplayMode()
        #expect(later.managedToolbar.displayMode == .labelOnly, "A later window keeps the mode it restored")
    }

    @Test("Turning labels off puts the icons back alone")
    func turningOffHidesLabels() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLabelsRecord(defaults: storage.defaults)
        record.record(true)
        let owner = Self.owner(labelsOn: false, record: record, mode: .iconAndLabel)

        owner.reconcileDisplayMode()

        #expect(owner.managedToolbar.displayMode == .iconOnly)
        #expect(!record.isApplied)
    }

    /// Someone who picked Icon and Text from the toolbar's menu without ever using the layout keeps it.
    @Test("With labels never asked for, the toolbar keeps its mode and nothing is written")
    func labelsNeverAskedForLeaveTheModeAlone() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLabelsRecord(defaults: storage.defaults)
        let owner = Self.owner(labelsOn: false, record: record, mode: .iconAndLabel)

        owner.reconcileDisplayMode()

        #expect(owner.managedToolbar.displayMode == .iconAndLabel)
        #expect(storage.defaults.object(forKey: ToolbarLabelsRecord.key) == nil)
    }

    /// A change made while no connection window is open is left for the first window that opens,
    /// which restores its saved mode before it reconciles.
    @Test("A toolbar outside a window leaves the change for the next one")
    func noWindowLeavesTheChangeForTheNextOne() throws {
        let storage = try EphemeralDefaults()
        let record = ToolbarLabelsRecord(defaults: storage.defaults)
        let owner = Self.owner(labelsOn: true, record: record)
        owner.isInWindow = { false }

        owner.reconcileDisplayMode()
        #expect(owner.managedToolbar.displayMode == .iconOnly)
        #expect(!record.isApplied)

        owner.isInWindow = { true }
        owner.reconcileDisplayMode()
        #expect(owner.managedToolbar.displayMode == .iconAndLabel)
        #expect(record.isApplied)
    }

    /// The labeled toolbar is the one that keeps a content command in place, so the key the visibility is
    /// resolved from carries the setting, and a change of it re-resolves the set.
    @Test("The visibility key follows the labels setting")
    func visibilityKeyFollowsTheLabels() throws {
        let storage = try EphemeralDefaults()
        let labeled = Self.owner(labelsOn: true, record: ToolbarLabelsRecord(defaults: storage.defaults))
        let plain = Self.owner(labelsOn: false, record: ToolbarLabelsRecord(defaults: storage.defaults))

        #expect(labeled.currentVisibilityKey().keepsContentCommandsInPlace)
        #expect(!plain.currentVisibilityKey().keepsContentCommandsInPlace)
    }

    @Test("With labels the window title stops drawing, and without them it draws again")
    func labelsHideTheTitle() {
        #expect(MainWindowToolbar.titleVisibility(showsLabels: true) == .hidden)
        #expect(MainWindowToolbar.titleVisibility(showsLabels: false) == .visible)
    }

    @Test("The record sits beside the toolbar's arrangement, which keeps its v4 identifier")
    func recordKeyFollowsTheArrangement() {
        #expect(ToolbarLabelsRecord.key == "com.TablePro.main.toolbar.v4.labels")
        #expect(MainWindowToolbar.toolbarIdentifier == "com.TablePro.main.toolbar.v4")
    }
}
