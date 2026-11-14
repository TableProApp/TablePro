//
//  FakeShareService.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport

@MainActor
final class FakeShareService: ShareService {
    var limitsResults: [Result<ShareLimits, ShareFailure>]
    var createResult: Result<CreatedShare, ShareFailure> = .success(
        CreatedShare(id: "shr_1", url: URL(string: "https://s.tablepro.app/abc")!)
    )
    var linksResult: Result<[ShareLink], ShareFailure> = .success([])
    var revokeFailure: ShareFailure?
    var fetchResults: [Result<SharedQuery, ShareFailure>] = []
    var createGate: AsyncGate?
    var fetchGate: AsyncGate?

    private(set) var limitsCalls = 0
    private(set) var drafts: [ShareDraft] = []
    private(set) var revokedIDs: [String] = []
    private(set) var fetchedPasswords: [String?] = []
    private(set) var linkTeams: [String?] = []

    init(limits: ShareLimits = .free()) {
        limitsResults = [.success(limits)]
    }

    // The protocol is nonisolated, so each call hops to the main actor to read and record.
    nonisolated func limits() async throws(ShareFailure) -> ShareLimits {
        try await nextLimits().get()
    }

    nonisolated func create(_ draft: ShareDraft) async throws(ShareFailure) -> CreatedShare {
        let gate = await record(draft)
        await gate?.wait()
        return try await createResultNow().get()
    }

    nonisolated func liveLinks(teamID: String?) async throws(ShareFailure) -> [ShareLink] {
        try await linksResult(for: teamID).get()
    }

    nonisolated func revoke(id: String) async throws(ShareFailure) {
        if let failure = await recordRevoke(id) { throw failure }
    }

    nonisolated func fetchShared(token: String, password: String?) async throws(ShareFailure) -> SharedQuery {
        let gate = await recordFetch(password)
        await gate?.wait()
        // A cancelled URL load answers as cancelled, whatever the server would have said.
        if Task.isCancelled { throw .canceled }
        return try await nextFetch().get()
    }

    private func nextLimits() -> Result<ShareLimits, ShareFailure> {
        limitsCalls += 1
        return limitsResults.count > 1 ? limitsResults.removeFirst() : limitsResults[0]
    }

    private func record(_ draft: ShareDraft) -> AsyncGate? {
        drafts.append(draft)
        return createGate
    }

    private func createResultNow() -> Result<CreatedShare, ShareFailure> {
        createResult
    }

    private func linksResult(for teamID: String?) -> Result<[ShareLink], ShareFailure> {
        linkTeams.append(teamID)
        return linksResult
    }

    private func recordRevoke(_ id: String) -> ShareFailure? {
        revokedIDs.append(id)
        return revokeFailure
    }

    private func recordFetch(_ password: String?) -> AsyncGate? {
        fetchedPasswords.append(password)
        return fetchGate
    }

    private func nextFetch() -> Result<SharedQuery, ShareFailure> {
        guard !fetchResults.isEmpty else { return .failure(.notFound) }
        return fetchResults.removeFirst()
    }
}

extension ShareLimits {
    static func free(live: Int = 3, emailVerified: Bool = true, sharingDisabled: Bool = false) -> ShareLimits {
        ShareLimits(
            plan: .free,
            live: live,
            liveLimit: 5,
            maxRows: 1_000,
            expiries: [.oneDay, .sevenDays, .thirtyDays],
            defaultExpiry: .thirtyDays,
            allowsPassword: false,
            allowsDisablingDownload: false,
            allowsTeamLinks: false,
            emailVerified: emailVerified,
            sharingDisabled: sharingDisabled
        )
    }

    static func pro(live: Int = 12, teams: [ShareTeam] = []) -> ShareLimits {
        ShareLimits(
            plan: .pro,
            live: live,
            liveLimit: 1_000,
            maxRows: 10_000,
            expiries: [.oneDay, .sevenDays, .thirtyDays, .never],
            defaultExpiry: .never,
            allowsPassword: true,
            allowsDisablingDownload: true,
            allowsTeamLinks: true,
            emailVerified: true,
            sharingDisabled: false,
            teams: teams
        )
    }
}
