import Combine
import Foundation
import TableProFFI

extension AppState {
    func teamKeysModel(for team: TeamLibraryTeam) -> TeamKeysModel {
        let host = syncCoordinator.host
        return TeamKeysModel(
            team: TeamKeysTeam(team),
            service: TeamKeysLiveCalls(host: host),
            changes: host.keyChanges.merge(with: host.reopened, host.signInChanges).eraseToAnyPublisher()
        )
    }
}
