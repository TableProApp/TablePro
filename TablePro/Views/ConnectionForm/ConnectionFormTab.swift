//
//  ConnectionFormTab.swift
//  TablePro
//

import Foundation

/// The facets of one connection.
///
/// A tab bar rather than a sidebar because a connection is a single object: a sidebar is how
/// macOS navigates between peer items, and there is only ever one item here. The set is fixed
/// except for Network, so the form does not change shape between database types.
enum ConnectionFormTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case network
    case options
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .network: return String(localized: "Network")
        case .options: return String(localized: "Options")
        case .appearance: return String(localized: "Appearance")
        }
    }

    /// One glyph per section, all four distinct at a glance.
    ///
    /// The eleven-pane sidebar this replaced ran two clouds and two locks against each other, so
    /// the icons said less than the labels did.
    var systemImage: String {
        switch self {
        case .general: return "info.circle"
        case .network: return "network"
        case .options: return "slider.horizontal.3"
        case .appearance: return "paintpalette"
        }
    }

    /// What is stopping this tab from being savable, in the words the user needs to fix it.
    ///
    /// These strings were computed and thrown away before: the form showed a warning triangle
    /// and a disabled Save and never said which field was empty.
    @MainActor
    func validationIssues(for coordinator: ConnectionFormCoordinator) -> [String] {
        switch self {
        case .general:
            return coordinator.network.validationIssues + coordinator.auth.validationIssues
        case .network:
            let groups: [[String]] = [
                coordinator.ssh.validationIssues,
                coordinator.remoteFile.validationIssues,
                coordinator.cloudflareTunnel.validationIssues,
                coordinator.cloudSQLProxy.validationIssues,
                coordinator.socksProxy.validationIssues,
                coordinator.tunnelCommand.validationIssues,
                coordinator.ssl.validationIssues
            ]
            return groups.flatMap { $0 }
        case .options:
            /// `customization` is claimed here rather than by Appearance because Safe Mode is the
            /// only control it owns that could ever fail a rule, and Safe Mode renders on this tab.
            /// Claiming it by view model instead would send the user to a tab with no such control.
            return coordinator.advanced.validationIssues + coordinator.customization.validationIssues
        case .appearance:
            return []
        }
    }
}
