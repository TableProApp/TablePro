import AppKit
@testable import TablePro
import Testing

@MainActor
struct ExternalConnectionFilterDisclosureTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Local", host: "127.0.0.1", port: 5_432,
            database: "shop", username: "postgres", type: .postgresql
        )
    }

    private func shownFilter(in alert: NSAlert) -> String? {
        let scroll = alert.accessoryView as? NSScrollView
        return (scroll?.documentView as? NSTextView)?.string
    }

    @Test("The whole condition is shown, however long")
    func showsWholeCondition() {
        let condition = "id > 0" + String(repeating: " ", count: 400) + "OR (SELECT pg_sleep(30)) IS NULL"
        let alert = ExternalConnectionAlertPrompt.makeAlert(
            for: connection(), filter: .condition(condition), offerAlwaysAllow: false
        )
        #expect(shownFilter(in: alert) == condition)
    }

    @Test("Invisible characters in the condition are revealed")
    func revealsInvisibleCharacters() throws {
        let alert = ExternalConnectionAlertPrompt.makeAlert(
            for: connection(), filter: .condition("id = 1\u{202E}--"), offerAlwaysAllow: false
        )
        let shown = try #require(shownFilter(in: alert))
        #expect(!shown.contains("\u{202E}"))
        #expect(shown.contains("<RLO>"))
    }

    @Test("A column filter is shown as column, operation and value")
    func showsColumnFilter() {
        let alert = ExternalConnectionAlertPrompt.makeAlert(
            for: connection(),
            filter: .column(name: "status", operation: "=", value: "active"),
            offerAlwaysAllow: false
        )
        #expect(shownFilter(in: alert) == "status = active")
    }

    @Test("The target is still named next to the filter")
    func namesTargetWithFilter() {
        let alert = ExternalConnectionAlertPrompt.makeAlert(
            for: connection(), filter: .condition("id > 0"), offerAlwaysAllow: false
        )
        #expect(alert.informativeText.contains("127.0.0.1:5432"))
        #expect(alert.informativeText.contains("shop"))
        #expect(alert.buttons.count == 2)
    }

    @Test("The filter box shows a scroller whenever the filter overflows it")
    func overflowShowsScroller() throws {
        let padded = "id > 0" + String(repeating: "\n", count: 40) + "OR (SELECT pg_sleep(30)) IS NULL"
        let alert = ExternalConnectionAlertPrompt.makeAlert(
            for: connection(), filter: .condition(padded), offerAlwaysAllow: false
        )
        let box = try #require(alert.accessoryView as? NSScrollView)
        #expect(box.scrollerStyle == .legacy)
        #expect(box.autohidesScrollers)
        #expect(shownFilter(in: alert) == padded)
    }

    @Test("A link without a filter shows no filter box")
    func noFilterNoAccessory() {
        let alert = ExternalConnectionAlertPrompt.makeAlert(for: connection(), offerAlwaysAllow: true)
        #expect(alert.accessoryView == nil)
    }
}
