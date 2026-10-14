import AppKit
import Foundation
import TableProUtilities
import Testing

// Hostless on purpose: AppKit files the record in the process's standard domain, which here is the
// test runner's rather than the app's com.TablePro.
@MainActor
struct SplitViewAutosaveKeyTests {
    @Test("The key prefix is the one AppKit actually writes")
    func keyPrefixMatchesAppKit() {
        let name = "SplitViewAutosaveKeyTests-\(UUID().uuidString)"
        // swiftlint:disable:next storage_environment_defaults
        let defaults = UserDefaults.standard
        let key = SplitViewAutosaveKey.key(forAutosaveName: name)
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        for _ in 0 ..< 2 {
            let pane = NSViewController()
            pane.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            controller.addSplitViewItem(NSSplitViewItem(viewController: pane))
        }
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.splitView.autosaveName = NSSplitView.AutosaveName(name)
        controller.splitView.setPosition(150, ofDividerAt: 0)

        // AppKit saves from a delayed perform, which only a default-mode run loop pass delivers.
        let deadline = Date(timeIntervalSinceNow: 10)
        while defaults.object(forKey: key) == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        #expect(
            defaults.object(forKey: key) != nil,
            "AppKit no longer writes its record under \(key), so the sweep matches a stale spelling"
        )
    }
}
