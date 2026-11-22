import XCTest

final class SettingsDrillInUITests: UITestCase {
    private enum Leaf {
        case hittable(String)
        case disabled(String)
        case present(String)
    }

    private struct Drill {
        let pane: String
        let paneTitle: String
        let page: String
        let pageTitle: String
        let leaf: Leaf?

        init(_ pane: String, _ paneTitle: String, page: String, title pageTitle: String, leaf: Leaf? = nil) {
            self.pane = pane
            self.paneTitle = paneTitle
            self.page = page
            self.pageTitle = pageTitle
            self.leaf = leaf
        }
    }

    // The UI test target cannot import the app, so these mirror SettingsPage's parents, titles and URL ids.
    private static let drills: [Drill] = [
        Drill("connections", "Connections", page: "linked-folders", title: "Linked Folders", leaf: .hittable("linked-folders-add-button")),
        // A new sandbox trusts no link, so Forget All has nothing to forget.
        Drill("connections", "Connections", page: "trusted-links", title: "Trusted Links", leaf: .disabled("trusted-links-forget-all-button")),
        Drill("data", "Data", page: "query-history", title: "Query History"),
        Drill("data", "Data", page: "data-rewind", title: "Data Rewind"),
        Drill("ai", "AI", page: "slash-commands", title: "Slash Commands", leaf: .present("slash-command-add")),
        Drill("editor", "Editor", page: "sql-formatting", title: "SQL Formatting"),
        Drill("general", "General", page: "command-line-tool", title: "Command Line Tool"),
    ]

    // One launch for every page: the UI plan pays for each launch. A page missing an environment object
    // its pane hands down crashes on push, so the walk catches that too.
    func testEveryPageOpensFromItsPaneAndBackReturnsThere() throws {
        let app = try launchApp()
        let settings = openSettings(in: app)
        let back = settingsNavigationButton("Back", in: settings)

        for drill in Self.drills {
            selectSettingsPane(drill.pane, page: drill.page, in: settings)
            XCTAssertTrue(
                waitForPredicate(timeout: 5) { settings.title == drill.pageTitle },
                "\(drill.pane)/\(drill.page) must title the window \(drill.pageTitle), it is \(settings.title)"
            )
            XCTAssertTrue(
                settingsPage(drill.page, in: settings).waitToExist(timeout: 5),
                "\(drill.pageTitle) must show settings-page-\(drill.page)"
            )
            if let leaf = drill.leaf {
                check(leaf, on: drill, in: settings)
            }

            XCTAssertTrue(
                waitForPredicate(timeout: 5) { back.exists && back.isEnabled },
                "\(drill.pageTitle) must enable Back"
            )
            back.click()
            XCTAssertTrue(
                waitForPredicate(timeout: 5) { settings.title == drill.paneTitle },
                "Back from \(drill.pageTitle) must return to \(drill.paneTitle), it is \(settings.title)"
            )
        }
    }

    private func check(_ leaf: Leaf, on drill: Drill, in settings: XCUIElement) {
        switch leaf {
        case .hittable(let identifier):
            XCTAssertTrue(
                waitUntilHittable(element(identifier, in: settings), timeout: 5),
                "\(drill.pageTitle) must show \(identifier) on screen"
            )
        case .disabled(let identifier):
            let control = element(identifier, in: settings)
            XCTAssertTrue(
                waitForPredicate(timeout: 5) { control.exists && !control.isEnabled },
                "\(drill.pageTitle) must show \(identifier), turned off in an empty sandbox"
            )
        case .present(let identifier):
            XCTAssertTrue(
                element(identifier, in: settings).waitToExist(timeout: 5),
                "\(drill.pageTitle) must show \(identifier)"
            )
        }
    }

    private func element(_ identifier: String, in settings: XCUIElement) -> XCUIElement {
        settings.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
