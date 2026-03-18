//
//  UpdaterBridge.swift
//  TablePro
//
//  Thin ObservableObject wrapping SPUStandardUpdaterController for SwiftUI integration
//

import Observation
import Sparkle

@Observable
@MainActor
final class UpdaterBridge {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    var canCheckForUpdates = false

    @ObservationIgnored private var observation: NSKeyValueObservation?

    deinit {
        observation?.invalidate()
        observation = nil
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe canCheckForUpdates via KVO
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let newValue = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = newValue
            }
        }
    }

    /// The underlying Sparkle updater for direct property access (e.g. automaticallyChecksForUpdates)
    var updater: SPUUpdater {
        controller.updater
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
