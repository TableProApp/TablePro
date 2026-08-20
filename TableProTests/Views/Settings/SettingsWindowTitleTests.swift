//
//  SettingsWindowTitleTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import XCTest

@MainActor
final class SettingsWindowTitleTests: XCTestCase {
    private var storedPane: String?
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        storedPane = AppStorageEnvironment.shared.defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name)
    }

    override func tearDown() {
        for window in windows {
            window.contentViewController = nil
            window.close()
        }
        windows = []
        if let storedPane {
            AppStorageEnvironment.shared.defaults.set(storedPane, forKey: PreferenceKeys.selectedSettingsPane.name)
        } else {
            AppStorageEnvironment.shared.defaults.removeObject(forKey: PreferenceKeys.selectedSettingsPane.name)
        }
        super.tearDown()
    }

    private func makePanes() -> (SettingsPaneTabViewController, NSWindow) {
        let panes = SettingsPaneTabViewController(nibName: nil, bundle: nil)
        let window = NSWindow(contentViewController: panes)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return (panes, window)
    }

    func testEveryPaneIsReachableAndCarriesItsOwnTitle() {
        let (panes, _) = makePanes()
        panes.loadViewIfNeeded()

        XCTAssertEqual(SettingsPaneTabViewController.paneOrder, SettingsPane.allCases)
        XCTAssertEqual(panes.tabViewItems.count, SettingsPane.allCases.count)
        for (item, pane) in zip(panes.tabViewItems, SettingsPane.allCases) {
            XCTAssertEqual(item.viewController?.title, pane.title)
            XCTAssertEqual(item.label, pane.title)
        }
    }

    /// `NSWindow(contentViewController:)` binds the window title to that controller's title and
    /// substitutes "Untitled" whenever it is nil, so a pane switch used to erase the title.
    func testTheWindowTitleFollowsTheSelectedPane() {
        let (panes, window) = makePanes()

        for pane in SettingsPane.allCases {
            panes.select(pane)
            XCTAssertEqual(window.title, pane.title)
        }
    }

    func testAFreshControllerOpensOnThePersistedPane() {
        AppStorageEnvironment.shared.defaults.set(
            SettingsPane.keyboard.rawValue,
            forKey: PreferenceKeys.selectedSettingsPane.name
        )

        let (_, window) = makePanes()

        XCTAssertEqual(window.title, SettingsPane.keyboard.title)
    }

    func testAskingForNoPaneReadsTheStoredPaneRatherThanStayingPut() {
        let (panes, window) = makePanes()
        panes.select(.plugins)
        XCTAssertEqual(window.title, SettingsPane.plugins.title)

        AppStorageEnvironment.shared.defaults.set(
            SettingsPane.editor.rawValue,
            forKey: PreferenceKeys.selectedSettingsPane.name
        )
        panes.select(nil)

        XCTAssertEqual(window.title, SettingsPane.editor.title)
    }

    func testTheWindowRefusesToShrinkBelowAPane() {
        let controller = SettingsWindowController()
        guard let window = controller.window else { return XCTFail("The controller must build a window") }
        windows.append(window)

        XCTAssertEqual(window.contentMinSize, SettingsPaneTabViewController.paneSize)
    }
}
