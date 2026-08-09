//
//  ConnectionStageObserver.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// Owned by the connecting view rather than the window controller. The window rebuilds its
/// panes only on a phase change, so holding the stage here keeps a stage tick from tearing
/// down and rebuilding the whole SwiftUI subtree.
@MainActor
@Observable
internal final class ConnectionStageObserver {
    internal private(set) var stage: ConnectionStage?
    internal private(set) var isTakingLonger = false

    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var patienceTask: Task<Void, Never>?

    private static let patience: Duration = .seconds(12)

    internal init(connectionId: UUID?) {
        guard let connectionId else { return }
        cancellable = AppEvents.shared.connectionStageChanged
            .filter { $0.connectionId == connectionId }
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.adopt(change.stage)
            }
        restartPatienceTimer()
    }

    deinit {
        patienceTask?.cancel()
    }

    private func adopt(_ next: ConnectionStage) {
        guard next != stage else { return }
        stage = next
        isTakingLonger = false
        restartPatienceTimer()
    }

    /// A step that has not changed in a while is the one case where the user cannot tell a slow
    /// server from a stalled app. Saying so is the whole difference between waiting and force
    /// quitting.
    private func restartPatienceTimer() {
        patienceTask?.cancel()
        patienceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            self?.isTakingLonger = true
        }
    }
}
