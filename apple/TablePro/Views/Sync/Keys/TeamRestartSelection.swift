//
//  TeamRestartSelection.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// Who a restart wraps the new team key to (core ADR 0056, Teams, No holder left): a member only after the person said
// the words of the key this Mac pinned for them match, and only while that is still the key this Mac has for them.
@MainActor
internal final class TeamRestartSelection: ObservableObject {
    @Published private(set) var words: [String: TeamFingerprintLoad] = [:]
    @Published private(set) var compared: [String: FingerprintInfo] = [:]
    @Published private(set) var changed: [String] = []

    private let service: any TeamKeysService

    init(service: any TeamKeysService) {
        self.service = service
    }

    func isIncluded(_ account: String) -> Bool {
        compared[account] != nil
    }

    func loadWords(_ account: String) async {
        if case .loaded? = words[account] { return }
        words[account] = .loading
        do {
            let fingerprint = try await service.accountFingerprint(account: account)
            words[account] = .loaded(fingerprint)
        } catch {
            words[account] = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load their words."))
        }
    }

    // Only words the person saw count, so a member whose words never loaded cannot be included.
    func wordsMatch(_ account: String) {
        guard case .loaded(let fingerprint)? = words[account] else { return }
        compared[account] = fingerprint
        changed.removeAll { $0 == account }
    }

    func exclude(_ account: String) {
        compared[account] = nil
    }

    // The included accounts, in roster order, each read again first: one whose words differ from the ones compared, or
    // that no longer reads at all, is dropped and named, and nothing is returned until the person compares it again.
    func accountsToWrap(in roster: [String]) async -> [String]? {
        var accounts: [String] = []
        var moved: [String] = []
        for account in roster {
            guard let seen = compared[account] else { continue }
            let current = try? await service.accountFingerprint(account: account)
            if current == seen {
                accounts.append(account)
            } else {
                compared[account] = nil
                words[account] = nil
                moved.append(account)
            }
        }
        changed = moved
        return moved.isEmpty ? accounts : nil
    }
}
