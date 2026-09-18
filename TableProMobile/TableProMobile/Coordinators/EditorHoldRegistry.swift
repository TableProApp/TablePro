import Foundation
import Observation

@MainActor @Observable
final class EditorHoldRegistry {
    private(set) var holdingScenes: [UUID: UUID] = [:]

    @ObservationIgnored private var releaseActions: [() -> Void] = []

    var isHolding: Bool { !holdingScenes.isEmpty }

    func isHolding(scene sceneId: UUID) -> Bool {
        holdingScenes.values.contains(sceneId)
    }

    func setHold(_ token: UUID, in sceneId: UUID, isHolding: Bool) {
        guard (holdingScenes[token] != nil) != isHolding else { return }
        guard isHolding else {
            holdingScenes.removeValue(forKey: token)
            runReleaseActionsIfReleased()
            return
        }
        holdingScenes[token] = sceneId
    }

    func performWhenReleased(_ action: @escaping () -> Void) {
        guard isHolding else {
            action()
            return
        }
        releaseActions.append(action)
    }

    private func runReleaseActionsIfReleased() {
        guard !isHolding, !releaseActions.isEmpty else { return }
        let actions = releaseActions
        releaseActions.removeAll()
        for action in actions {
            action()
        }
    }
}
