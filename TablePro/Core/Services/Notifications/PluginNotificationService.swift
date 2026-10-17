import Combine
import Foundation
import os
import UserNotifications

@MainActor
final class PluginNotificationService {
    static let shared = PluginNotificationService()

    static let identifierPrefix = "com.TablePro.plugin."
    static let openPluginSettingsActionId = "openPluginSettings"
    private static let updateFailedCategoryId = "com.TablePro.pluginUpdateFailed"
    private static let failedIdentifierPrefix = identifierPrefix + "failed."
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PluginNotifications")

    private var cancellables: Set<AnyCancellable> = []
    private var deliveredFailureIdentifiers: Set<String> = []

    private init() {}

    func setUp() {
        registerCategories()
        NotificationRouter.shared.register(self, forCategory: Self.updateFailedCategoryId)
        subscribeToEvents()
    }

    func notifyAutoUpdateFailed(plugins: [RejectedPlugin]) async {
        guard !plugins.isEmpty else { return }
        guard await NotificationAuthorization.shared.ensureAuthorized() else { return }

        let center = UNUserNotificationCenter.current()
        let incomingIdentifiers = Set(plugins.map(Self.failureIdentifier))
        let staleIdentifiers = deliveredFailureIdentifiers.subtracting(incomingIdentifiers)
        if !staleIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(staleIdentifiers))
            deliveredFailureIdentifiers.subtract(staleIdentifiers)
        }

        for plugin in plugins {
            let content = UNMutableNotificationContent()
            content.title = String(format: String(localized: "%@ could not be loaded"), plugin.name)
            content.body = plugin.reason
            content.categoryIdentifier = Self.updateFailedCategoryId

            let identifier = Self.failureIdentifier(for: plugin)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                deliveredFailureIdentifiers.insert(identifier)
            } catch {
                Self.logger.error("Failed to post notification for '\(plugin.name)': \(error.localizedDescription)")
            }
        }
    }

    func clearPluginNotifications() async {
        let center = UNUserNotificationCenter.current()
        guard !deliveredFailureIdentifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(deliveredFailureIdentifiers))
        deliveredFailureIdentifiers.removeAll()
    }

    private static func failureIdentifier(for plugin: RejectedPlugin) -> String {
        let key = plugin.bundleId ?? plugin.registryId ?? plugin.name
        return failedIdentifierPrefix + key
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
        NotificationCategoryRegistry.shared.register([failedCategory], owner: "plugins")
    }

    private func subscribeToEvents() {
        AppEvents.shared.pluginsRejected
            .receive(on: RunLoop.main)
            .sink { [weak self] rejected in
                guard let self else { return }
                Task {
                    if rejected.isEmpty {
                        await self.clearPluginNotifications()
                    } else {
                        await self.notifyAutoUpdateFailed(plugins: rejected)
                    }
                }
            }
            .store(in: &cancellables)
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
        WindowOpener.shared.openSettings(tab: .plugins)
    }
}
