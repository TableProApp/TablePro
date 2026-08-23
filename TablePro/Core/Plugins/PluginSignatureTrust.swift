//
//  PluginSignatureTrust.swift
//  TablePro
//

import Foundation

/// What a plugin bundle's code signature entitles it to.
///
/// A driver plugin runs as code inside the app and holds database credentials, so an unsigned or
/// ad-hoc bundle is never loadable. The distinction that matters is between a bundle TablePro
/// signed itself, which loads silently, and one signed by another developer's Developer ID, which
/// loads only after the user has said yes to that developer by name.
internal enum PluginSignatureTrust: Equatable, Sendable {
    case firstParty
    case developerID(PluginDeveloperIdentity)

    internal var requiresUserConsent: Bool {
        switch self {
        case .firstParty: false
        case .developerID: true
        }
    }
}

/// The signing identity of a third-party plugin, as it is shown to the user and stored once trusted.
///
/// `teamID` is the key. It comes from `kSecCodeInfoTeamIdentifier`, is assigned by Apple, and cannot
/// be chosen by the signer, so two developers can never collide on it and a rename cannot move trust
/// from one to another. `name` is display only.
internal struct PluginDeveloperIdentity: Codable, Hashable, Identifiable, Sendable {
    internal let teamID: String
    internal let name: String

    internal var id: String { teamID }

    internal init(teamID: String, name: String) {
        self.teamID = teamID
        self.name = name
    }
}
