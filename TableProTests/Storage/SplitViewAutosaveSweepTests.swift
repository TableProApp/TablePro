//
//  SplitViewAutosaveSweepTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@Suite("SplitViewAutosaveSweep")
@MainActor
struct SplitViewAutosaveSweepTests {
    private func key(_ name: String) -> String {
        SplitViewAutosaveRecord.keyPrefix + name
    }

    private func retiredName(connectionId: UUID = UUID(), tabId: UUID = UUID()) -> String {
        "\(SplitViewAutosaveName.querySplitPrefix)\(connectionId.uuidString)-\(tabId.uuidString)"
    }

    // MARK: - The undocumented key spelling

    /// Apple documents `autosaveName` and nothing else: no key format, and no way to forget a
    /// record, which is why the sweep reaches into the domain by hand. The spelling is therefore a
    /// transcription, and this derives it from a real `NSSplitView` instead of trusting it.
    @Test("The key prefix is the one AppKit actually writes")
    func keyPrefixMatchesAppKit() {
        let name = "SplitViewAutosaveSweepTests-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let expected = key(name)
        defaults.removeObject(forKey: expected)

        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        for _ in 0 ..< 2 {
            let pane = NSViewController()
            pane.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            controller.addSplitViewItem(NSSplitViewItem(viewController: pane))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.splitView.autosaveName = NSSplitView.AutosaveName(name)
        window.orderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))

        defer {
            window.orderOut(nil)
            defaults.removeObject(forKey: expected)
        }
        #expect(
            defaults.object(forKey: expected) != nil,
            "AppKit no longer writes its record under \(expected), so the sweep matches a stale spelling"
        )
    }

    // MARK: - Parsing

    /// The retired name joined two UUIDs with the character that also separates their own groups, so
    /// the shape is recognised by length. A parser that searched for the hyphen would find one
    /// inside the connection id and read the rest as a tab.
    @Test("The retired per-tab name is recognised")
    func parsesRetiredPerTabName() {
        #expect(SplitViewAutosaveRecord.parse(key: key(retiredName())) == .retiredPerTabQuerySplit)
    }

    /// The name that replaced it carries one UUID, so it must not look retired.
    @Test("The per-connection name that replaced it is not treated as retired")
    func perConnectionNameIsNotRetired() {
        let current = SplitViewAutosaveName.querySplit(connectionId: UUID())
        #expect(SplitViewAutosaveRecord.parse(key: key(current)) == .unrecognised)
    }

    @Test("A key that is not an autosave record parses as nothing at all")
    func ignoresUnrelatedKeys() {
        #expect(SplitViewAutosaveRecord.parse(key: "com.TablePro.someSetting") == nil)
        #expect(SplitViewAutosaveRecord.parse(key: "NSWindow Frame ValueViewerWindow") == nil)
    }

    @Test(
        "A name the sweep does not own is unrecognised rather than guessed at",
        arguments: [
            "com.TablePro.mainSplit",
            "com.TablePro.usersRoles.privilegeSplit",
            "com.TablePro.queryPlanTreeSplit",
            "ServerDashboardSplit",
            "SomeNameAddedLater",
        ]
    )
    func otherNamesAreUnrecognised(name: String) {
        #expect(SplitViewAutosaveRecord.parse(key: key(name)) == .unrecognised)
    }

    @Test("A connection's history drawer is never touched")
    func historyDrawerIsUnrecognised() {
        let drawer = SplitViewAutosaveName.historyDrawer(connectionId: UUID())
        #expect(SplitViewAutosaveRecord.parse(key: key(drawer)) == .unrecognised)
    }

    /// `SplitViewAutosaveName.resolved` appends a sandbox suffix under a UI test, and the suffix is
    /// whatever the sandbox directory is called: measured on one machine as UUIDs and as `sandbox`,
    /// `sb`, `pr2`, `shot` and `sb-repro1`. A suffixed record belongs to a test case and must not be
    /// judged by a rule written for the real domain.
    @Test(
        "A sandbox-suffixed retired name is left alone",
        arguments: ["sandbox", "sb", "pr2", "shot", "sb-repro1", "0E5A1D48-1D0E-4F2E-9C21-2C19F0E3A77B"]
    )
    func sandboxSuffixedNamesAreUnrecognised(suffix: String) {
        #expect(SplitViewAutosaveRecord.parse(key: key("\(retiredName()).\(suffix)")) == .unrecognised)
    }

    @Test("A malformed identifier is unrecognised rather than parsed into a random UUID")
    func malformedIdentifiersAreUnrecognised() {
        #expect(SplitViewAutosaveRecord.parse(key: key("QuerySplit-")) == .unrecognised)
        #expect(SplitViewAutosaveRecord.parse(key: key("QuerySplit-nope-nope")) == .unrecognised)
        #expect(SplitViewAutosaveRecord.parse(key: key("HistoryDrawer-not-a-uuid")) == .unrecognised)
    }

    // MARK: - What gets swept

    /// No liveness enters into it: the family is unreachable from any code path, so a record under
    /// it is dead whichever connection and tab it names.
    @Test("Every retired record is swept, whichever connection it names")
    func sweepsEveryRetiredRecord() {
        let connectionId = UUID()
        let records = [
            key(retiredName(connectionId: connectionId)),
            key(retiredName(connectionId: connectionId)),
            key(retiredName()),
        ]
        #expect(Set(SplitViewAutosaveSweep.deadKeys(among: records)) == Set(records))
    }

    @Test("Nothing else is ever swept")
    func neverSweepsAnythingElse() {
        let untouchable = [
            key(SplitViewAutosaveName.querySplit(connectionId: UUID())),
            key(SplitViewAutosaveName.historyDrawer(connectionId: UUID())),
            key("com.TablePro.mainSplit"),
            key("com.TablePro.mainSplit.0E5A1D48-1D0E-4F2E-9C21-2C19F0E3A77B"),
            key("com.TablePro.usersRoles.mainSplit"),
            key("ServerDashboardSplit"),
            "com.TablePro.unrelatedSetting",
            "NSWindow Frame JSONViewerWindow",
        ]
        #expect(SplitViewAutosaveSweep.deadKeys(among: untouchable).isEmpty)
    }

    @Test("A mixed domain loses only its retired records")
    func sweepsOnlyRetiredFromAMixedDomain() {
        let retired = key(retiredName())
        let kept = [
            key(SplitViewAutosaveName.querySplit(connectionId: UUID())),
            key(SplitViewAutosaveName.historyDrawer(connectionId: UUID())),
            key("com.TablePro.mainSplit"),
        ]
        #expect(SplitViewAutosaveSweep.deadKeys(among: kept + [retired]) == [retired])
    }

    /// A record written under the name the app builds today must not be one the sweep removes, or
    /// the reader loses the divider they just set.
    @Test("The name the app builds today survives the sweep")
    func currentNameSurvives() {
        let connectionId = UUID()
        let current = key(SplitViewAutosaveName.querySplit(connectionId: connectionId))
        #expect(SplitViewAutosaveSweep.deadKeys(among: [current]).isEmpty)
    }
}
