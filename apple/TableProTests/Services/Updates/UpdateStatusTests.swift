import Foundation
@testable import TablePro
import Testing

struct AppUpdatePhaseTests {
    private static let release = UpdateRelease(version: "0.85.0", releaseNotesURL: URL(string: "https://docs.tablepro.app/changelog"))
    private static let newer = UpdateRelease(version: "0.85.1", releaseNotesURL: nil)

    @Test("A scheduled update Sparkle defers becomes available")
    func deferredUpdateIsAvailable() {
        #expect(AppUpdatePhase.idle.applying(.scheduledUpdateDeferred(Self.release)) == .available(Self.release))
    }

    @Test("Opening the deferred update or ending its session clears the reminder", arguments: [
        AppUpdateEvent.updateReceivedAttention,
        AppUpdateEvent.updateSessionFinished,
    ])
    func attentionClearsTheReminder(_ event: AppUpdateEvent) {
        #expect(AppUpdatePhase.available(Self.release).applying(event) == .idle)
        #expect(AppUpdatePhase.idle.applying(event) == .idle)
    }

    @Test("A download Sparkle finished on its own is ready to install, whatever was pending")
    func silentDownloadIsReady() {
        #expect(AppUpdatePhase.idle.applying(.readyToInstallOnQuit(Self.release)) == .readyToInstall(Self.release))
        #expect(AppUpdatePhase.available(Self.release).applying(.readyToInstallOnQuit(Self.release)) == .readyToInstall(Self.release))
    }

    @Test("Only a newer download replaces a ready update; reminders and sessions never clear it", arguments: [
        AppUpdateEvent.updateReceivedAttention,
        AppUpdateEvent.updateSessionFinished,
        AppUpdateEvent.scheduledUpdateDeferred(UpdateRelease(version: "0.86.0", releaseNotesURL: nil)),
    ])
    func readyIsSticky(_ event: AppUpdateEvent) {
        let ready = AppUpdatePhase.readyToInstall(Self.release)
        #expect(ready.applying(event) == ready)
        #expect(ready.applying(.readyToInstallOnQuit(Self.newer)) == .readyToInstall(Self.newer))
    }
}

extension AppUpdatePhaseTests {
    @Test("Sparkle abandoning an update clears it, ready or not", arguments: [
        AppUpdatePhase.available(UpdateRelease(version: "0.85.0", releaseNotesURL: nil)),
        AppUpdatePhase.readyToInstall(UpdateRelease(version: "0.85.0", releaseNotesURL: nil)),
    ])
    func abortClearsTheUpdate(_ phase: AppUpdatePhase) {
        #expect(phase.applying(.updateAborted) == .idle)
    }
}

struct UpdateStatusTests {
    private static let release = UpdateRelease(version: "0.85.0", releaseNotesURL: URL(string: "https://docs.tablepro.app/changelog"))
    private static let postgres = StagedPluginUpdate(name: "PostgreSQL", version: "1.4.2")
    private static let mongo = StagedPluginUpdate(name: "MongoDB", version: nil)

    @Test("Nothing pending shows no indicator and offers a check")
    func nothingPending() {
        let status = UpdateStatus()

        #expect(status.indicator == .hidden)
        #expect(status.indicatorTitle == nil)
        #expect(status.menuTitle == "Check for Updates…")
    }

    @Test("A deferred update reads Update Available, and its menu item opens a window")
    func availableUpdate() {
        let status = UpdateStatus(app: .available(Self.release))

        #expect(status.indicator == .updateAvailable)
        #expect(status.indicatorTitle == "Update Available")
        #expect(status.menuTitle.hasSuffix("…"))
        #expect(status.indicatorHelp?.contains("0.85.0") == true)
    }

    @Test("A downloaded update reads Relaunch to Update, and its menu item acts at once")
    func readyUpdate() {
        let status = UpdateStatus(app: .readyToInstall(Self.release))

        #expect(status.indicator == .relaunchToUpdate)
        #expect(status.indicatorTitle == "Relaunch to Update")
        #expect(status.menuTitle == "Relaunch to Update")
        #expect(!status.menuTitle.hasSuffix("…"))
    }

    @Test("Staged plugins alone ask for a relaunch, but never answer a notice that needs a newer app")
    func stagedPluginsAlone() {
        let status = UpdateStatus(stagedPlugins: [Self.postgres])

        #expect(status.indicator == .relaunchToUpdate)
        #expect(status.appUpdateTitle == "Check for Updates…")
        #expect(UpdateStatus(app: .readyToInstall(Self.release), stagedPlugins: [Self.postgres]).appUpdateTitle == "Relaunch to Update")
    }

    @Test("An app update not yet downloaded wins over staged plugins, since installing it relaunches")
    func availableWinsOverStagedPlugins() {
        #expect(UpdateStatus(app: .available(Self.release), stagedPlugins: [Self.postgres]).indicator == .updateAvailable)
    }

    @Test("Staged plugins list by name, and a version shows only when the staged bundle has one")
    func stagedPluginsSortAndName() {
        let status = UpdateStatus(stagedPlugins: [Self.postgres, Self.mongo])

        #expect(status.stagedPlugins.map { $0.name } == ["MongoDB", "PostgreSQL"])
        #expect(status.stagedPlugins.map { $0.displayName } == ["MongoDB", "PostgreSQL 1.4.2"])
    }

    @Test("The Settings row checks when idle and says when it last did")
    func idleSummary() {
        let never = UpdateStatus().summary(currentVersion: "0.84.0", lastChecked: nil)

        #expect(never.headline == "TablePro 0.84.0")
        #expect(never.detail == "Last checked: never")
        #expect(never.actionTitle == "Check Now")

        let checked = UpdateStatus().summary(currentVersion: "0.84.0", lastChecked: Date(timeIntervalSince1970: 0))
        #expect(checked.detail.hasPrefix("Last checked: "))
        #expect(checked.detail != never.detail)
    }

    @Test("The Settings row names the waiting version and the action that finishes it")
    func pendingSummaries() {
        let available = UpdateStatus(app: .available(Self.release)).summary(currentVersion: "0.84.0", lastChecked: nil)
        #expect(available.headline == "TablePro 0.85.0 is available")
        #expect(available.actionTitle == "Install Update…")

        let ready = UpdateStatus(app: .readyToInstall(Self.release)).summary(currentVersion: "0.84.0", lastChecked: nil)
        #expect(ready.headline == "TablePro 0.85.0 is ready to install")
        #expect(ready.actionTitle == "Relaunch")
    }

    @Test("The Settings row names one staged plugin and counts several")
    func stagedPluginSummaries() {
        let one = UpdateStatus(stagedPlugins: [Self.postgres]).summary(currentVersion: "0.84.0", lastChecked: nil)
        #expect(one.headline == "TablePro 0.84.0")
        #expect(one.detail == "PostgreSQL 1.4.2 updates when TablePro relaunches.")
        #expect(one.actionTitle == "Relaunch")

        let two = UpdateStatus(stagedPlugins: [Self.postgres, Self.mongo]).summary(currentVersion: "0.84.0", lastChecked: nil)
        #expect(two.detail == "2 plugins update when TablePro relaunches.")
    }

    @Test("The popover lists staged plugins under the app update, or on their own")
    func popoverContent() {
        let both = UpdateStatus(app: .readyToInstall(Self.release), stagedPlugins: [Self.postgres])
        #expect(both.readyTitle == "TablePro 0.85.0 is ready to install")
        #expect(both.stagedPluginsHeader == "Also updating:")

        let pluginsOnly = UpdateStatus(stagedPlugins: [Self.postgres])
        #expect(pluginsOnly.readyTitle == "Plugin updates are ready")
        #expect(pluginsOnly.stagedPluginsHeader == nil)
        #expect(pluginsOnly.readyMessage != both.readyMessage)
    }
}
