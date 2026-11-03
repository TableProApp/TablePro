import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let releaseNotesURL: URL?
}

enum AppUpdatePhase: Equatable, Sendable {
    case idle
    case available(UpdateRelease)
    case readyToInstall(UpdateRelease)
}

enum AppUpdateEvent: Equatable, Sendable {
    case scheduledUpdateDeferred(UpdateRelease)
    case updateReceivedAttention
    case updateSessionFinished
    case readyToInstallOnQuit(UpdateRelease)
    case updateAborted
}

extension AppUpdatePhase {
    // A downloaded update installs on quit whatever later sessions do; only Sparkle giving it up clears it.
    func applying(_ event: AppUpdateEvent) -> AppUpdatePhase {
        switch (self, event) {
        case (_, .readyToInstallOnQuit(let release)):
            return .readyToInstall(release)
        case (_, .updateAborted):
            return .idle
        case (.readyToInstall, _):
            return self
        case (_, .scheduledUpdateDeferred(let release)):
            return .available(release)
        case (.available, .updateReceivedAttention), (.available, .updateSessionFinished):
            return .idle
        case (.idle, .updateReceivedAttention), (.idle, .updateSessionFinished):
            return self
        }
    }

    var release: UpdateRelease? {
        switch self {
        case .idle: nil
        case .available(let release), .readyToInstall(let release): release
        }
    }
}

struct StagedPluginUpdate: Equatable, Hashable, Sendable {
    let name: String
    let version: String?
}

enum UpdateIndicator: Equatable, Sendable {
    case hidden
    case updateAvailable
    case relaunchToUpdate
}

struct UpdateStatus: Equatable, Sendable {
    var app: AppUpdatePhase
    var stagedPlugins: [StagedPluginUpdate]

    init(app: AppUpdatePhase = .idle, stagedPlugins: [StagedPluginUpdate] = []) {
        self.app = app
        self.stagedPlugins = stagedPlugins.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // An app update not yet downloaded wins over staged plugins: installing it relaunches, which applies them too.
    var indicator: UpdateIndicator {
        switch app {
        case .readyToInstall: .relaunchToUpdate
        case .available: .updateAvailable
        case .idle: stagedPlugins.isEmpty ? .hidden : .relaunchToUpdate
        }
    }

    var readyAppRelease: UpdateRelease? {
        guard case .readyToInstall(let release) = app else { return nil }
        return release
    }
}
