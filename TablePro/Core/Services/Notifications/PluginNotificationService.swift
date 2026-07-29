//
//  PluginNotificationService.swift
//  TablePro
//

import Combine
import Foundation
import os
import UserNotifications

@MainActor @Observable
final class PluginNotificationService {
    static let shared = PluginNotificationService()

    static let identifierPrefix = "com.TablePro.plugin."
    static let openPluginSettingsActionId = "openPluginSettings"
    private static let updateFailedCategoryId = "com.TablePro.pluginUpdateFailed"
    private static let failedIdentifierPrefix = identifierPrefix + "failed."
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginNotifications")

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var didRequestPermission = false
    @ObservationIgnored private var deliveredFailureIdentifiers: Set<String> = []

    private init() {}

    func setUp() {
        registerCategories()
        subscribeToEvents()
        Task { await refreshAuthorizationStatus() }
    }

    func requestPermissionIfNeeded() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined, !didRequestPermission else { return }
        didRequestPermission = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge])
            Self.logger.info("Notification permission \(granted ? "granted" : "denied")")
        } catch {
            Self.logger.error("Notification permission request failed: \(error.localizedDescription)")
        }
        await refreshAuthorizationStatus()
    }

    func notifyAutoUpdateFailed(plugins: [RejectedPlugin]) async {
        guard !plugins.isEmpty else { return }
        await requestPermissionIfNeeded()
        guard authorizationStatus == .authorized else { return }

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
        UNUserNotificationCenter.current().setNotificationCategories([failedCategory])
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

    private func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }
}
