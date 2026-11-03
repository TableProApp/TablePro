import AppKit
import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
final class UpdateCenterFixture {
    let phase = CurrentValueSubject<AppUpdatePhase, Never>(.idle)
    let plugins = CurrentValueSubject<[StagedPluginUpdate], Never>([])
    let canCheck = CurrentValueSubject<Bool, Never>(false)
    private(set) var checks = 0
    private(set) var relaunches = 0
    private(set) var center: UpdateCenter!

    init() {
        center = UpdateCenter(
            appPhase: phase.eraseToAnyPublisher(),
            stagedPlugins: plugins.eraseToAnyPublisher(),
            canCheckForUpdates: canCheck.eraseToAnyPublisher(),
            checkForUpdates: { [unowned self] in checks += 1 },
            relaunch: { [unowned self] in relaunches += 1 }
        )
    }

    static let release = UpdateRelease(version: "0.85.0", releaseNotesURL: nil)
}

@MainActor
struct UpdateCenterTests {
    @Test("The status follows the updater's phase and the staged plugins")
    func statusFollowsItsSources() {
        let fixture = UpdateCenterFixture()

        fixture.phase.send(.available(UpdateCenterFixture.release))
        #expect(fixture.center.status.indicator == .updateAvailable)

        fixture.phase.send(.idle)
        fixture.plugins.send([StagedPluginUpdate(name: "PostgreSQL", version: "1.4.2")])
        #expect(fixture.center.status.indicator == .relaunchToUpdate)
    }

    @Test("Checking and a deferred update open Sparkle's window; a ready update relaunches")
    func primaryActionRoutes() {
        let fixture = UpdateCenterFixture()

        fixture.center.performPrimaryAction()
        fixture.phase.send(.available(UpdateCenterFixture.release))
        fixture.center.performPrimaryAction()
        #expect(fixture.checks == 2)
        #expect(fixture.relaunches == 0)

        fixture.phase.send(.readyToInstall(UpdateCenterFixture.release))
        fixture.center.performPrimaryAction()
        #expect(fixture.checks == 2)
        #expect(fixture.relaunches == 1)
    }

    @Test("A notice that needs a newer app checks for one even when only plugins are staged")
    func appUpdateActionIgnoresStagedPlugins() {
        let fixture = UpdateCenterFixture()
        fixture.plugins.send([StagedPluginUpdate(name: "PostgreSQL", version: nil)])
        fixture.canCheck.send(true)

        fixture.center.performAppUpdateAction()
        #expect(fixture.checks == 1)
        #expect(fixture.relaunches == 0)

        fixture.canCheck.send(false)
        #expect(!fixture.center.isAppUpdateActionEnabled)

        fixture.phase.send(.readyToInstall(UpdateCenterFixture.release))
        #expect(fixture.center.isAppUpdateActionEnabled)
        fixture.center.performAppUpdateAction()
        #expect(fixture.relaunches == 1)
    }

    @Test("A pending update stays actionable when Sparkle cannot start a new check")
    func pendingUpdateIsActionableWithoutChecks() {
        let fixture = UpdateCenterFixture()
        #expect(!fixture.center.isPrimaryActionEnabled)

        fixture.canCheck.send(true)
        #expect(fixture.center.isPrimaryActionEnabled)

        fixture.canCheck.send(false)
        fixture.phase.send(.readyToInstall(UpdateCenterFixture.release))
        #expect(fixture.center.isPrimaryActionEnabled)
    }
}

@MainActor
struct UpdateIndicatorAccessoryTests {
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "UpdateIndicatorAccessoryTests")
        return window
    }

    @Test("The indicator joins the titlebar only while something is pending")
    func installsOnlyWhilePending() {
        let fixture = UpdateCenterFixture()
        let window = Self.makeWindow()
        let accessory = UpdateIndicatorAccessory(window: window, center: fixture.center)
        #expect(!accessory.isInstalled)

        fixture.phase.send(.available(UpdateCenterFixture.release))
        #expect(accessory.isInstalled)
        #expect(accessory.controller.layoutAttribute == .trailing)
        #expect(accessory.controller.button.title == "Update Available")

        fixture.phase.send(.readyToInstall(UpdateCenterFixture.release))
        #expect(accessory.isInstalled)
        #expect(accessory.controller.button.title == "Relaunch to Update")
        #expect(window.titlebarAccessoryViewControllers.count { $0 === accessory.controller } == 1)

        fixture.phase.send(.idle)
        #expect(!accessory.isInstalled)
        window.orderOut(nil)
    }

    @Test("Staged plugins alone show the indicator, and it leaves when they are gone")
    func removedWhenNothingIsPending() {
        let fixture = UpdateCenterFixture()
        let window = Self.makeWindow()
        let accessory = UpdateIndicatorAccessory(window: window, center: fixture.center)

        fixture.plugins.send([StagedPluginUpdate(name: "PostgreSQL", version: nil)])
        #expect(accessory.isInstalled)

        fixture.plugins.send([])
        #expect(!accessory.isInstalled)
        window.orderOut(nil)
    }

    @Test("Update Available opens Sparkle's window rather than a popover")
    func updateAvailableClickChecks() {
        let fixture = UpdateCenterFixture()
        let window = Self.makeWindow()
        let accessory = UpdateIndicatorAccessory(window: window, center: fixture.center)

        fixture.phase.send(.available(UpdateCenterFixture.release))
        accessory.controller.button.performClick(nil)

        #expect(fixture.checks == 1)
        #expect(fixture.relaunches == 0)
        window.orderOut(nil)
    }
}
