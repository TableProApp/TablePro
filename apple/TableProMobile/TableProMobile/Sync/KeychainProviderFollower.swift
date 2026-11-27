import Combine
import Foundation
import os
import TableProFFI

// The Keychain follows the provider the sync engine reports (core ADR 0054, Providers), as on the Mac. On TablePro
// Sync each iCloud Keychain item gets a copy of this device's own and stays where it is, since removing it removes it on
// every device still on iCloud; from then on secrets live in this device's items and their envelopes. Back on iCloud,
// or with sync off, the password switch decides again.
@MainActor
final class KeychainProviderFollower {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainProviderFollower")

    private let addCopies: @Sendable () -> Bool
    private let record: any KeychainProviderRecord
    private var subscription: AnyCancellable?
    private var copying: Task<Void, Never>?
    // Each provider adopted, so copies that finish after a move back mark nothing.
    private var generation = 0

    init(addCopies: @escaping @Sendable () -> Bool, record: any KeychainProviderRecord = DefaultsKeychainProviderRecord()) {
        self.addCopies = addCopies
        self.record = record
    }

    // Only reads the engine once it is open, whatever provider it was opened for: following it never opens it.
    func start(host: IOSSyncEngineHost) {
        start(changes: host.statusChanges.eraseToAnyPublisher()) { [weak host] in
            host?.openedEngine(for: .off)?.status().provider
        }
    }

    // Copies a locked Keychain left unfinished at the last launch are tried again here.
    func start(changes: AnyPublisher<Void, Never>, provider: @escaping @MainActor () -> SyncProviderTag?) {
        guard subscription == nil else { return }
        subscription = changes
            .sink { [weak self] in
                guard let provider = provider() else { return }
                self?.follow(provider)
            }
        addCopiesIfOwed()
    }

    func follow(_ provider: SyncProviderTag) {
        let current = record.state
        switch provider {
        case .tableproSync:
            guard !current.onTableProSync else {
                addCopiesIfOwed()
                return
            }
            generation += 1
            record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: false))
            addCopiesIfOwed()
        case .icloud, .off:
            guard current != .followsPasswordSync else { return }
            generation += 1
            record.store(.followsPasswordSync)
        }
    }

    func copiesSettled() async {
        await copying?.value
    }

    // Off the main actor: a Keychain call is a round trip to securityd per item.
    private func addCopiesIfOwed() {
        let state = record.state
        guard state.onTableProSync, !state.deviceCopiesAdded, copying == nil else { return }
        let turn = generation
        copying = Task { [addCopies] in
            let complete = await Task.detached { addCopies() }.value
            self.copiesFinished(complete: complete, turn: turn)
        }
    }

    private func copiesFinished(complete: Bool, turn: Int) {
        copying = nil
        guard turn == generation else {
            addCopiesIfOwed()
            return
        }
        guard record.state.onTableProSync else { return }
        guard complete else {
            Self.logger.notice("Not every iCloud Keychain item has a copy on this device yet; trying again later")
            return
        }
        record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
    }
}
