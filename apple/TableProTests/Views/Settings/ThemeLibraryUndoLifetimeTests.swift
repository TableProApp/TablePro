import AppKit
@testable import TablePro
import SwiftUI
import TableProTheme
import Testing

// The Manage Themes page used to own its model, so Cmd-Z after Back reached a released undo target.
@MainActor
struct ThemeLibraryUndoLifetimeTests {
    private typealias Fixture = ThemeLibraryTestFixture

    @Test("Undo of a trash made on Manage Themes restores the theme and its slot after the page is gone")
    func undoAfterThePageIsReleased() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        fixture.selection.themeSelection.preferredDarkThemeId = "user.aaaa0002"
        let library = fixture.makeLibrary()

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsSplitViewController.detailWidth,
                height: SettingsSplitViewController.minimumContentSize.height
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let undoManager = try #require(window.undoManager)
        undoManager.groupsByEvent = false

        window.contentViewController = NSHostingController(rootView: ThemeLibrarySection(model: library))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        undoManager.beginUndoGrouping()
        #expect(library.moveToTrash(.theme("user.aaaa0002"), undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(fixture.catalog.theme(id: "user.aaaa0002") == nil)
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == BuiltInThemes.defaultDarkId)

        // Releasing the host stands in for Back popping the page.
        window.contentViewController = nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(fixture.catalog.theme(id: "user.aaaa0002")?.name == "Midnight")
        #expect(try fixture.fileNames() == ["user.aaaa0002.json"])
        #expect(fixture.selection.themeSelection.preferredDarkThemeId == "user.aaaa0002")
        #expect(library.alert == nil)
    }

    @Test("A theme undo that fails off the Manage Themes page shows its error on the Settings window")
    func offPageErrorReachesTheWindow() throws {
        let fixture = try Fixture()
        try fixture.install(Fixture.theme("user.aaaa0001", "Paper", appearance: .light))
        try fixture.install(Fixture.theme("user.aaaa0002", "Midnight"))
        let library = fixture.makeLibrary()
        let registry = try OfflineRegistry()
        let navigation = SettingsNavigationModel(initial: .root(.appearance))
        let shown = PresentedErrors()
        let context = SettingsPaneContext(
            pane: .appearance,
            settings: .shared,
            navigation: navigation,
            models: SettingsWindowModels(),
            registryClient: registry.client,
            presentError: { title, _ in shown.titles.append(title) }
        )
        AppearanceStackPresentations.routeOffPageAlerts(of: library, to: context)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        #expect(library.rename("user.aaaa0002", to: "Night Owl", undoManager: undoManager) == .renamed("Night Owl"))
        undoManager.endUndoGrouping()
        #expect(library.rename("user.aaaa0001", to: "Midnight", undoManager: nil) == .renamed("Midnight"))
        undoManager.undo()
        #expect(shown.titles == ["Couldn't Rename the Theme"])
        #expect(library.alert == nil)

        #expect(navigation.push(.page(.manageThemes), in: .appearance))
        let broken = try fixture.writeIncoming("Monokai.json", contents: Data("[]".utf8))
        _ = library.importThemes(from: [broken], undoManager: nil)
        #expect(library.alert?.title == "Couldn't Import “Monokai.json”")
        #expect(shown.titles.count == 1)
    }
}

@MainActor
private final class PresentedErrors {
    var titles: [String] = []
}
