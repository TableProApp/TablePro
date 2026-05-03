//
//  NewsletterPromptCoordinator.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor
final class NewsletterPromptCoordinator {
    static let shared = NewsletterPromptCoordinator()

    static let promptThreshold = 3
    static let subscribeURL = URL(string: "https://tablepro.app/?subscribe=true&source=mac")

    private static let logger = Logger(subsystem: "com.TablePro", category: "NewsletterPrompt")

    private var observer: NSObjectProtocol?
    private let provider: MacAnalyticsProvider
    private let workspace: NSWorkspace

    private init(provider: MacAnalyticsProvider = .shared, workspace: NSWorkspace = .shared) {
        self.provider = provider
        self.workspace = workspace
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .successfulConnectionRecorded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAndPresent()
            }
        }
    }

    func evaluateAndPresent() {
        guard !provider.newsletterPromptShown,
              provider.successfulConnectionCount >= Self.promptThreshold else {
            return
        }
        present()
    }

    private func present() {
        provider.markNewsletterPromptShown()

        let alert = NSAlert()
        alert.messageText = String(localized: "Stay updated on TablePro releases")
        alert.informativeText = String(localized: "Get release notes and database tips by email. No spam, unsubscribe anytime.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Subscribe in Browser"))
        alert.addButton(withTitle: String(localized: "Maybe later"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let url = Self.subscribeURL else {
            Self.logger.error("Newsletter subscribe URL is invalid")
            return
        }
        workspace.open(url)
    }
}
