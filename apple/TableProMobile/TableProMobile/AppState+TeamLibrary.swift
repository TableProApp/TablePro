import Combine
import Foundation
import TableProFFI

extension AppState {
    // One Team Library per app state, made on first use and started then, so the connection list and its sheets show
    // the same teams.
    var teamLibrary: TeamLibraryModel {
        TeamLibraryModels.model(for: self)
    }

    func teamKeysModel(for team: TeamLibraryTeam) -> TeamKeysModel {
        let host = syncCoordinator.host
        return TeamKeysModel(
            team: TeamKeysTeam(team),
            service: TeamKeysLiveCalls(host: host),
            changes: host.keyChanges.merge(with: host.reopened).eraseToAnyPublisher()
        )
    }
}

@MainActor
private enum TeamLibraryModels {
    static var byState: [ObjectIdentifier: TeamLibraryModel] = [:]

    static func model(for state: AppState) -> TeamLibraryModel {
        let key = ObjectIdentifier(state)
        if let model = byState[key] {
            return model
        }
        let model = TeamLibraryModel(source: .live(host: state.syncCoordinator.host, account: state.account))
        byState[key] = model
        model.start()
        return model
    }
}
