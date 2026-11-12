import Combine
import Foundation
import os
import UserNotifications

@MainActor
final class PluginNotificationService {
    static let shared = PluginNotificationService()

    static let identifierPrefix = "com.TablePro.plugin."
    static let openPluginSettingsActionId = "openPluginSettings"
    static let pluginIdKey = "pluginId"
    private static let updateFailedCategoryId = "com.TablePro.pluginUpdateFailed"
    private static let rejectedIdentifierPrefix = identifierPrefix + "failed."
    private static let updateFailedIdentifierPrefix = identifierPrefix + "updateFailed."
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PluginNotifications")

    private let presenter: any UserNotificationPresenting
    private let authorization: NotificationAuthorization
    private let categories: NotificationCategoryRegistry
    private let tracker: PluginInstallTracker
    private let settings: () -> NotificationSettings

    private var cancellables: Set<AnyCancellable> = []
    private var deliveredRejectedIdentifiers: Set<String> = []
    private var deliveredUpdateFailures: Set<String> = []
    private var handledFailureGenerations: Set<UUID> = []

    init(
        presenter: any UserNotificationPresenting = SystemNotificationPresenter.shared,
        authorization: NotificationAuthorization = .shared,
        categories: NotificationCategoryRegistry = .shared,
        tracker: PluginInstallTracker = .shared,
        settings: (() -> NotificationSettings)? = nil
    ) {
        self.presenter = presenter
        self.authorization = authorization
        self.categories = categories
        self.tracker = tracker
        self.settings = settings ?? { AppSettingsManager.shared.notifications }
    }

    func setUp() {
        registerCategories()
        NotificationRouter.shared.register(self, forCategory: Self.updateFailedCategoryId)
        AppEvents.shared.pluginsRejected
            .receive(on: RunLoop.main)
            .sink { [weak self] rejected in
                guard let self else { return }
                Task { await self.notifyRejected(rejected) }
            }
            .store(in: &cancellables)
        observeInstalls()
    }

    func observeInstalls() {
        tracker.$entries
            .sink { [weak self] entries in self?.render(entries) }
            .store(in: &cancellables)
    }

    // A plugin already notified stays quiet until it leaves the rejected list, so each connect does not post it again.
    func notifyRejected(_ plugins: [RejectedPlugin]) async {
        let incoming = Set(plugins.map(Self.rejectedIdentifier))
        let stale = deliveredRejectedIdentifiers.subtracting(incoming)
        if !stale.isEmpty {
            presenter.removeDelivered(identifiers: Array(stale))
            deliveredRejectedIdentifiers.subtract(stale)
        }

        let fresh = plugins.filter { !deliveredRejectedIdentifiers.contains(Self.rejectedIdentifier(for: $0)) }
        guard !fresh.isEmpty, settings().isEnabled else { return }
        deliveredRejectedIdentifiers.formUnion(fresh.map(Self.rejectedIdentifier))
        guard await authorization.ensureAuthorized() else { return }

        for plugin in fresh {
            await post(
                identifier: Self.rejectedIdentifier(for: plugin),
                title: String(format: String(localized: "%@ could not be loaded"), plugin.name),
                body: plugin.reason,
                pluginId: plugin.registryId ?? plugin.bundleId
            )
        }
    }

    private func render(_ entries: [String: PluginInstallTracker.Entry]) {
        for entry in entries.values {
            switch entry.phase {
            case .failed(let reason):
                guard entry.trigger == .update, handledFailureGenerations.insert(entry.generation).inserted else { continue }
                notifyUpdateFailed(entry, reason: reason)
            case .completed:
                clearFailures(forPluginId: entry.pluginId)
            case .downloading, .installing:
                if entry.trigger == .user {
                    clearFailures(forPluginId: entry.pluginId)
                }
            }
        }
    }

    private func notifyUpdateFailed(_ entry: PluginInstallTracker.Entry, reason: String) {
        guard !deliveredUpdateFailures.contains(entry.pluginId), settings().isEnabled else { return }
        deliveredUpdateFailures.insert(entry.pluginId)
        Task {
            guard await authorization.ensureAuthorized() else { return }
            // A manual retry or a later install may have cleared it during the permission prompt.
            guard deliveredUpdateFailures.contains(entry.pluginId) else { return }
            await post(
                identifier: Self.updateFailedIdentifierPrefix + entry.pluginId,
                title: String(format: String(localized: "%@ could not be updated"), entry.displayName),
                body: reason,
                pluginId: entry.pluginId
            )
        }
    }

    private func clearFailures(forPluginId pluginId: String) {
        var identifiers: [String] = []
        if deliveredUpdateFailures.remove(pluginId) != nil {
            identifiers.append(Self.updateFailedIdentifierPrefix + pluginId)
        }
        let rejected = Self.rejectedIdentifierPrefix + pluginId
        if deliveredRejectedIdentifiers.remove(rejected) != nil {
            identifiers.append(rejected)
        }
        guard !identifiers.isEmpty else { return }
        presenter.removeDelivered(identifiers: identifiers)
    }

    private func post(identifier: String, title: String, body: String, pluginId: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.updateFailedCategoryId
        if let pluginId {
            content.userInfo = [Self.pluginIdKey: pluginId]
        }
        do {
            try await presenter.post(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
            Self.logger.error("Failed to post a plugin notification: \(error.publicLogShape, privacy: .public)")
        }
    }

    private static func rejectedIdentifier(for plugin: RejectedPlugin) -> String {
        rejectedIdentifierPrefix + (plugin.bundleId ?? plugin.registryId ?? plugin.name)
    }

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: Self.openPluginSettingsActionId,
            title: String(localized: "Open Plugin Settings"),
            options: [.foreground]
        )
        let failedCategory = UNNotificationCategory(
            identifier: Self.updateFailedCategoryId,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        categories.register([failedCategory], owner: "plugins")
    }
}

extension PluginNotificationService: NotificationHandling {
    func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func handle(_ response: UNNotificationResponse) {
        let action = response.actionIdentifier
        guard action == Self.openPluginSettingsActionId || action == UNNotificationDefaultActionIdentifier
        else { return }
        let pluginId = response.notification.request.content.userInfo[Self.pluginIdKey] as? String
        PluginsSettingsNavigation.shared.reveal(pluginId: pluginId)
        WindowOpener.shared.openSettings(tab: .plugins)
    }
}
