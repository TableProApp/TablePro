//
//  LicenseManager+Team.swift
//  TablePro
//
//  The roster of a Team license
//

import Foundation
import os

extension LicenseManager {
    /// Whether this license is entitled to a team roster.
    ///
    /// Asked through `unlocks` rather than an equality check, so a tier this build has never heard
    /// of, which ranks above every known one, is not denied something it has paid for.
    var showsTeamRoster: Bool {
        guard let license else { return false }
        return license.isTeamLicense || currentTier.unlocks(.team)
    }

    /// Load the team's seats and members.
    ///
    /// Read-only by necessity: invites and removals are behind a token-authenticated API the app
    /// cannot authenticate against, so the roster links out to the web for anything that writes.
    func loadTeam(force: Bool = false) async {
        guard let license, showsTeamRoster else { return }
        guard force || teamListState == .idle else { return }

        if !teamListState.hasContent {
            teamListState = .loading
        }

        do {
            team = try await LicenseAPIClient.shared.teamInfo(
                licenseKey: license.key,
                machineId: currentMachineId
            )
            teamListState = .loaded
        } catch {
            let message = (error as? LicenseError)?.friendlyDescription ?? error.localizedDescription
            Self.deviceLogger.warning("Failed to load team roster: \(error.localizedDescription)")
            /// A roster already on screen survives a refresh that could not reach the server.
            if !teamListState.hasContent {
                teamListState = .failed(message)
            }
        }
    }

    func resetTeam() {
        team = nil
        teamListState = .idle
    }
}
