import Foundation

struct SoftwareUpdateSummary: Equatable {
    let headline: String
    let detail: String
    let actionTitle: String
}

extension UpdateStatus {
    var menuTitle: String {
        switch indicator {
        case .hidden: String(localized: "Check for Updates…")
        case .updateAvailable: String(localized: "Update Available…")
        case .relaunchToUpdate: String(localized: "Relaunch to Update")
        }
    }

    // For a notice that needs a newer TablePro: staged plugins alone never satisfy it.
    var appUpdateTitle: String {
        switch app {
        case .idle: String(localized: "Check for Updates…")
        case .available: String(localized: "Update Available…")
        case .readyToInstall: String(localized: "Relaunch to Update")
        }
    }

    var indicatorTitle: String? {
        switch indicator {
        case .hidden: nil
        case .updateAvailable: String(localized: "Update Available")
        case .relaunchToUpdate: String(localized: "Relaunch to Update")
        }
    }

    var indicatorHelp: String? {
        switch indicator {
        case .hidden:
            return nil
        case .updateAvailable:
            guard let release = app.release else { return nil }
            return String(format: String(localized: "TablePro %@ is available."), release.version)
        case .relaunchToUpdate:
            return String(localized: "Relaunch TablePro to finish updating.")
        }
    }

    func summary(currentVersion: String, lastChecked: Date?) -> SoftwareUpdateSummary {
        let lastCheckedText = lastChecked.map {
            String(format: String(localized: "Last checked: %@"), $0.formatted(date: .abbreviated, time: .shortened))
        } ?? String(localized: "Last checked: never")
        let current = String(format: String(localized: "TablePro %@"), currentVersion)

        switch app {
        case .readyToInstall(let release):
            return SoftwareUpdateSummary(
                headline: String(format: String(localized: "TablePro %@ is ready to install"), release.version),
                detail: String(localized: "Relaunch TablePro to finish updating."),
                actionTitle: String(localized: "Relaunch")
            )
        case .available(let release):
            return SoftwareUpdateSummary(
                headline: String(format: String(localized: "TablePro %@ is available"), release.version),
                detail: lastCheckedText,
                actionTitle: String(localized: "Install Update…")
            )
        case .idle:
            guard let pluginsLine = stagedPluginsSentence else {
                return SoftwareUpdateSummary(
                    headline: current,
                    detail: lastCheckedText,
                    actionTitle: String(localized: "Check Now")
                )
            }
            return SoftwareUpdateSummary(
                headline: current,
                detail: pluginsLine,
                actionTitle: String(localized: "Relaunch")
            )
        }
    }

    var readyTitle: String {
        guard let release = readyAppRelease else { return String(localized: "Plugin updates are ready") }
        return String(format: String(localized: "TablePro %@ is ready to install"), release.version)
    }

    var readyMessage: String {
        readyAppRelease == nil
            ? String(localized: "TablePro relaunches to load them and reopens your connections.")
            : String(localized: "TablePro relaunches to install it and reopens your connections.")
    }

    var stagedPluginsHeader: String? {
        guard !stagedPlugins.isEmpty, readyAppRelease != nil else { return nil }
        return String(localized: "Also updating:")
    }

    private var stagedPluginsSentence: String? {
        switch stagedPlugins.count {
        case 0:
            return nil
        case 1:
            return String(format: String(localized: "%@ updates when TablePro relaunches."), stagedPlugins[0].displayName)
        default:
            return String(format: String(localized: "%lld plugins update when TablePro relaunches."), stagedPlugins.count)
        }
    }
}

extension StagedPluginUpdate {
    var displayName: String {
        guard let version else { return name }
        return "\(name) \(version)"
    }
}
