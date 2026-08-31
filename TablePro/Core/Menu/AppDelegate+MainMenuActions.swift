//
//  AppDelegate+MainMenuActions.swift
//  TablePro
//

import AppKit

/// Commands that belong to the app rather than to any one window. They sit on the
/// app delegate because it is the last link in the responder chain, so they stay
/// reachable with no window open at all.
extension AppDelegate: NSMenuItemValidation {
    @objc func showAboutPanel(_ sender: Any?) {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: AboutPanelCredits.attributedString()])
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        AcknowledgementsWindowController.present()
    }

    @objc func showSupport(_ sender: Any?) {
        SupportWindowController.present()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdaterBridge.shared.checkForUpdates()
    }

    @objc func openIntegrations(_ sender: Any?) {
        WindowOpener.shared.openIntegrationsActivity()
    }

    @objc func openSettings(_ sender: Any?) {
        WindowOpener.shared.openSettings()
    }

    @objc func newConnection(_ sender: Any?) {
        WindowOpener.shared.openConnectionForm()
    }

    @objc func manageConnections(_ sender: Any?) {
        WindowOpener.shared.openWelcome()
    }

    /// A database file, a connection share and a plugin all open without a live connection, so
    /// this belongs to the app and not to an editor window that may not exist.
    @objc func openFile(_ sender: Any?) {
        Task { @MainActor in
            guard let urls = await FileOpenPanel.present() else { return }
            for url in urls {
                guard case .some(.success(let intent)) = URLClassifier.classify(url) else { continue }
                await LaunchIntentRouter.shared.route(intent)
            }
        }
    }

    @objc func compareAndSyncDatabases(_ sender: Any?) {
        CompareSyncLauncher.open()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        RecentlyClosedTabReopener.reopenMostRecent()
    }

    @objc func exportConnections(_ sender: Any?) {
        WelcomeRouter.shared.route(.exportConnections)
    }

    @objc func importConnections(_ sender: Any?) {
        WelcomeRouter.shared.route(.importConnections)
    }

    @objc func importFromURL(_ sender: Any?) {
        WelcomeRouter.shared.route(.importFromURL)
    }

    @objc func importFromOtherApp(_ sender: Any?) {
        WelcomeRouter.shared.route(.importFromApp)
    }

    @objc func openSampleDatabase(_ sender: Any?) {
        SampleDatabaseLauncher.open()
    }

    @objc func resetSampleDatabase(_ sender: Any?) {
        SampleDatabaseLauncher.reset()
    }

    @objc func openWebsite(_ sender: Any?) {
        open(MainMenuLink.website)
    }

    @objc func openDocumentation(_ sender: Any?) {
        open(MainMenuLink.documentation)
    }

    @objc func openGitHubRepository(_ sender: Any?) {
        open(MainMenuLink.repository)
    }

    @objc func reportAnIssue(_ sender: Any?) {
        open(MainMenuLink.issues)
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkForUpdates(_:)):
            return UpdaterBridge.shared.canCheckForUpdates
        case #selector(reopenClosedTab(_:)):
            return !RecentlyClosedTabStore.shared.entries.isEmpty
        default:
            return true
        }
    }
}

enum MainMenuLink {
    static let website = "https://tablepro.app"
    static let documentation = "https://docs.tablepro.app"
    static let repository = "https://github.com/TableProApp/TablePro"
    static let issues = "https://github.com/TableProApp/TablePro/issues"
}

/// The About panel's credits line, kept out of the delegate so the menu action stays
/// a single call.
enum AboutPanelCredits {
    static func attributedString() -> NSAttributedString {
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let credits = NSMutableAttributedString()
        let links: [(String, String)] = [
            ("Website", MainMenuLink.website),
            ("GitHub", MainMenuLink.repository),
            (String(localized: "Documentation"), MainMenuLink.documentation),
            (String(localized: "Sponsor"), SupportLinks.sponsors(.aboutPanel).absoluteString)
        ]
        for (index, link) in links.enumerated() {
            if index > 0 {
                credits.append(NSAttributedString(string: "  |  ", attributes: style))
            }
            let attributed = NSMutableAttributedString(string: link.0, attributes: style)
            if let url = URL(string: link.1) {
                attributed.addAttribute(.link, value: url, range: NSRange(location: 0, length: attributed.length))
            }
            credits.append(attributed)
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        return credits
    }
}
