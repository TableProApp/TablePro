//
//  TeamLibrarySavedQueriesPublishing.swift
//  TablePro
//

import AppKit

// One publish of every saved query and folder for the Favorites menu and File > Publish Saved Queries to Team.
@MainActor
internal enum TeamLibrarySavedQueriesPublishing {
    static func publish(
        to teamID: String,
        through library: TeamLibrary = .shared,
        showConflicts: @escaping @MainActor () -> Void
    ) {
        let destination = library.destination(teamID)
        Task { @MainActor in
            let favorites = await SQLFavoriteManager.shared.fetchFavorites()
            let folders = await SQLFavoriteManager.shared.fetchFolders()
            guard !favorites.isEmpty else {
                AlertHelper.showInfoSheet(
                    title: String(localized: "Team Library"),
                    message: String(localized: "You have no saved queries to publish."),
                    window: nil
                )
                return
            }
            guard await confirm(count: favorites.count) else { return }
            let outcome: TeamLibraryPublishOutcome
            do throws(TeamLibraryPublishError) {
                outcome = .finished(try await library.publishSavedQueries(
                    favorites: favorites,
                    folders: folders,
                    to: destination
                ))
            } catch {
                outcome = .failed(error)
            }
            TeamLibraryPublishing.present(outcome, showConflicts: showConflicts)
        }
    }

    private static func confirm(count: Int) async -> Bool {
        await AlertHelper.confirm(
            title: String(localized: "Publish saved queries to your team?"),
            message: String(
                format: String(
                    localized: "Your team will see the names and SQL of %d saved queries. Queries you published from this Mac and deleted since are removed from the team library."
                ),
                count
            ),
            confirmButton: String(localized: "Publish"),
            window: nil
        )
    }
}

// File > Publish Saved Queries to Team, one row per team this account writes, filled when it opens.
@MainActor
internal final class TeamPublishMenuDelegate: NSObject, NSMenuDelegate {
    private let teams: @MainActor () -> [TeamLibraryTeam]

    internal init(teams: @escaping @MainActor () -> [TeamLibraryTeam] = TeamPublishMenuDelegate.writableTeams) {
        self.teams = teams
    }

    internal static func writableTeams() -> [TeamLibraryTeam] {
        guard FeatureAccess.shared.isAvailable(.teamLibrary) else { return [] }
        return TeamLibrary.shared.writableTeams
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for team in teams() {
            let item = NSMenuItem(
                title: String(format: String(localized: "%@…"), team.name),
                action: #selector(AppDelegate.publishSavedQueriesToTeam(_:)),
                keyEquivalent: ""
            )
            item.representedObject = team.id
            menu.addItem(item)
        }
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}

// The File menu shows the submenu only while the account writes a team's library.
@MainActor
internal enum TeamPublishMenuGroup {
    internal static let identifier = NSUserInterfaceItemIdentifier("file.teamLibrary.publishSavedQueries")

    internal static func update(in menu: NSMenu, teams: [TeamLibraryTeam] = TeamPublishMenuDelegate.writableTeams()) {
        guard let item = menu.items.first(where: { $0.identifier == identifier }) else { return }
        let hidden = teams.isEmpty
        if item.isHidden != hidden {
            item.isHidden = hidden
        }
    }
}
