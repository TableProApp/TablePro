import Combine
import Foundation

@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter(
        appPhase: SoftwareUpdater.shared.$phase.eraseToAnyPublisher(),
        stagedPlugins: PluginManager.shared.stagedPluginUpdatesPublisher,
        canCheckForUpdates: SoftwareUpdater.shared.$canCheckForUpdates.eraseToAnyPublisher(),
        checkForUpdates: { SoftwareUpdater.shared.checkForUpdates() },
        relaunch: { AppRelauncher.shared.relaunch() }
    )

    @Published private(set) var status = UpdateStatus()
    @Published private(set) var canCheckForUpdates = false

    private let checkForUpdatesAction: @MainActor () -> Void
    private let relaunchAction: @MainActor () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        appPhase: AnyPublisher<AppUpdatePhase, Never>,
        stagedPlugins: AnyPublisher<[StagedPluginUpdate], Never>,
        canCheckForUpdates: AnyPublisher<Bool, Never>,
        checkForUpdates: @escaping @MainActor () -> Void,
        relaunch: @escaping @MainActor () -> Void
    ) {
        checkForUpdatesAction = checkForUpdates
        relaunchAction = relaunch
        appPhase.combineLatest(stagedPlugins)
            .map { UpdateStatus(app: $0, stagedPlugins: $1) }
            .removeDuplicates()
            .sink { [weak self] in self?.status = $0 }
            .store(in: &cancellables)
        canCheckForUpdates
            .removeDuplicates()
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    // A pending update is acted on even when Sparkle could not start a fresh check.
    var isPrimaryActionEnabled: Bool {
        status.indicator != .hidden || canCheckForUpdates
    }

    // Sparkle's own window shows a deferred update; checking again is how its docs bring it forward.
    func performPrimaryAction() {
        switch status.indicator {
        case .hidden, .updateAvailable: checkForUpdatesAction()
        case .relaunchToUpdate: relaunchAction()
        }
    }

    var isAppUpdateActionEnabled: Bool {
        status.app != .idle || canCheckForUpdates
    }

    func performAppUpdateAction() {
        switch status.app {
        case .idle, .available: checkForUpdatesAction()
        case .readyToInstall: relaunchAction()
        }
    }

    func relaunch() {
        relaunchAction()
    }
}

extension PluginManager {
    var stagedPluginUpdatesPublisher: AnyPublisher<[StagedPluginUpdate], Never> {
        $stagedPluginIds.combineLatest($plugins)
            .map { [userPluginsDir] ids, plugins in
                plugins.filter { ids.contains($0.id) }.map { entry in
                    StagedPluginUpdate(
                        name: entry.name,
                        version: Self.stagedVersion(of: entry.id, in: userPluginsDir)
                    )
                }
            }
            .eraseToAnyPublisher()
    }

    nonisolated static func stagedVersion(of pluginId: String, in userPluginsDir: URL) -> String? {
        let directory = PluginInstaller.stagedUpdateDirectory(for: pluginId, in: userPluginsDir)
        guard let bundleURL = try? PluginInstaller.findBundle(in: directory),
              let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) else {
            return nil
        }
        return info["CFBundleShortVersionString"] as? String
    }
}
