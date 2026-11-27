//
//  TeamRestartSelectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

@MainActor
struct TeamRestartSelectionTests {
    private typealias F = TeamKeysFixtures

    private let service = FakeTeamKeysService()

    private func fingerprint(_ words: [String]) -> FingerprintInfo {
        FingerprintInfo(words: words, qr: F.qr)
    }

    @Test("Nobody is included before their words loaded and the person said they match")
    func includesOnlyAfterComparing() async {
        let selection = TeamRestartSelection(service: service)

        selection.wordsMatch(F.ana)
        #expect(!selection.isIncluded(F.ana))

        service.update { $0.failures["accountFingerprint"] = F.failure("keys.unendorsed") }
        await selection.loadWords(F.ana)
        selection.wordsMatch(F.ana)
        #expect(!selection.isIncluded(F.ana))

        service.update { $0.failures["accountFingerprint"] = nil }
        await selection.loadWords(F.ana)
        selection.wordsMatch(F.ana)
        #expect(selection.isIncluded(F.ana))
    }

    @Test("The restart wraps to the compared members in roster order")
    func wrapsToTheCompared() async {
        let selection = TeamRestartSelection(service: service)
        for account in [F.bo, F.ana] {
            await selection.loadWords(account)
            selection.wordsMatch(account)
        }
        await selection.loadWords(F.you)

        let accounts = await selection.accountsToWrap(in: [F.ana, F.bo, F.you])

        #expect(accounts == [F.ana, F.bo])
    }

    @Test("A member whose words changed after the comparison is dropped and named, and nothing goes up")
    func changedWordsStopTheRestart() async {
        service.update { $0.fingerprints[F.ana] = fingerprint(F.words) }
        let selection = TeamRestartSelection(service: service)
        await selection.loadWords(F.ana)
        selection.wordsMatch(F.ana)
        service.update { $0.fingerprints[F.ana] = fingerprint(F.otherWords) }

        let accounts = await selection.accountsToWrap(in: [F.ana])

        #expect(accounts == nil)
        #expect(selection.changed == [F.ana])
        #expect(!selection.isIncluded(F.ana))
    }

    @Test("A member whose words no longer read is dropped too")
    func unreadableWordsStopTheRestart() async {
        let selection = TeamRestartSelection(service: service)
        await selection.loadWords(F.ana)
        selection.wordsMatch(F.ana)
        service.update { $0.failures["accountFingerprint"] = F.failure("sync.network") }

        #expect(await selection.accountsToWrap(in: [F.ana]) == nil)
        #expect(selection.changed == [F.ana])
    }
}
