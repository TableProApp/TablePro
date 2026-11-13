//
//  ShareSheetModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct ShareSheetModelTests {
    private final class Box {
        var copied: [String] = []
        var signedIn: Bool
        let signIns = PassthroughSubject<Bool, Never>()

        init(signedIn: Bool) {
            self.signedIn = signedIn
        }
    }

    private static func source(rows: Int, total: Int??, sql: String) -> ShareResultSource {
        ShareResultSource(
            columns: ["id", "api_key"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text")],
            rows: (0..<rows).map { [.text(String($0)), .text("k\($0)")] },
            totalRowCount: total ?? rows,
            sql: sql
        )
    }

    private static func resultRequest(rows: Int = 3, total: Int?? = .none, sql: String = "SELECT id FROM users") -> ShareRequest {
        .result(title: "Users", dialect: "PostgreSQL", source: source(rows: rows, total: total, sql: sql))
    }

    private static func link(_ id: String, at seconds: TimeInterval = 0) -> ShareLink {
        ShareLink(
            id: id, title: id, kind: .query, createdAt: Date(timeIntervalSince1970: seconds), expiresAt: nil, isSuspended: false
        )
    }

    private static let acme = ShareTeam(id: "team_acme", name: "Acme", live: 4, liveLimit: 1_000, allowsPublicLinks: true)
    private static let closed = ShareTeam(id: "team_closed", name: "Closed", live: 0, liveLimit: 1_000, allowsPublicLinks: false)

    private func makeModel(
        _ request: ShareRequest = .query(title: "Report", sql: "SELECT 1", dialect: "MySQL"),
        service: FakeShareService,
        box: Box = Box(signedIn: true)
    ) -> ShareSheetModel {
        ShareSheetModel(
            request: request,
            service: service,
            isSignedIn: { box.signedIn },
            signInChanges: box.signIns.eraseToAnyPublisher(),
            copyToClipboard: { box.copied.append($0) }
        )
    }

    private func formatted(_ key: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: String(localized: key), locale: .current, arguments: arguments)
    }

    // MARK: - Phases

    @Test("Signed out shows the sign-in prompt and asks the server nothing")
    func signedOut() async {
        let service = FakeShareService()
        let model = makeModel(service: service, box: Box(signedIn: false))
        await model.load()
        #expect(model.phase == .signedOut)
        #expect(service.limitsCalls == 0)
    }

    @Test("Signing in from the prompt loads the limits")
    func signingInLoads() async throws {
        let service = FakeShareService()
        let box = Box(signedIn: false)
        let model = makeModel(service: service, box: box)
        await model.load()

        box.signedIn = true
        box.signIns.send(true)
        try await waitUntil { model.phase == .form }
        #expect(service.limitsCalls == 1)
    }

    @Test("An unverified email stops at Open Account")
    func emailUnverified() async {
        let model = makeModel(service: FakeShareService(limits: .free(emailVerified: false)))
        await model.load()
        #expect(model.phase == .emailUnverified)
    }

    @Test("Sharing turned off for the account stops at its message")
    func sharingDisabled() async {
        let model = makeModel(service: FakeShareService(limits: .free(sharingDisabled: true)))
        await model.load()
        #expect(model.phase == .sharingDisabled)
    }

    @Test("Offline shows the offline message with a retry that recovers")
    func offlineThenRetry() async {
        let service = FakeShareService()
        service.limitsResults = [.failure(.offline), .success(.free())]
        let model = makeModel(service: service)

        await model.load()
        #expect(model.phase == .loadFailed(String(localized: "You appear to be offline. Try again once you're connected.")))

        await model.load()
        #expect(model.phase == .form)
    }

    @Test("A refused session on load returns to the sign-in prompt")
    func refusedSessionSignsOut() async {
        let service = FakeShareService()
        service.limitsResults = [.failure(.signedOut)]
        let model = makeModel(service: service)
        await model.load()
        #expect(model.phase == .signedOut)
    }

    // MARK: - Plan gating

    @Test("Free defaults to 30 days and cannot pick Never, a password or turning downloads off")
    func freeGating() async throws {
        let model = makeModel(service: FakeShareService(limits: .free()))
        await model.load()

        #expect(model.expiry == .thirtyDays)
        #expect(!model.isAvailable(.never))
        #expect(model.isAvailable(.oneDay))

        model.expiry = .never
        model.password = "secret"
        model.allowsDownload = false
        let draft = try #require(model.makeDraft())
        #expect(draft.expiry == .thirtyDays)
        #expect(draft.password == nil)
        #expect(draft.allowsDownload == nil)
    }

    @Test("Pro defaults to Never and sends a password and turned-off downloads")
    func proOptions() async throws {
        let model = makeModel(service: FakeShareService(limits: .pro()))
        await model.load()

        #expect(model.expiry == .never)
        #expect(model.isAvailable(.never))

        model.password = "hunter2"
        model.allowsDownload = false
        let draft = try #require(model.makeDraft())
        #expect(draft.expiry == .never)
        #expect(draft.password == "hunter2")
        #expect(draft.allowsDownload == false)
    }

    @Test("Downloads left on are not sent, so the server keeps its default")
    func downloadsDefault() async throws {
        let model = makeModel(service: FakeShareService(limits: .pro()))
        await model.load()
        #expect(try #require(model.makeDraft()).allowsDownload == nil)
    }

    @Test("The footer names the plan and its usage")
    func footer() async {
        let free = makeModel(service: FakeShareService(limits: .free(live: 3)))
        await free.load()
        #expect(free.footer == formatted("Free · %1$lld of %2$lld links · first %3$lld rows", Int64(3), Int64(5), Int64(1_000)))

        let pro = makeModel(service: FakeShareService(limits: .pro(live: 12)))
        await pro.load()
        #expect(pro.footer == formatted("Pro · %lld links", Int64(12)))
    }

    @Test("A password over 128 characters and SQL over 262,144 characters block Create with a reason")
    func fieldLimitsBlockCreate() async {
        let model = makeModel(service: FakeShareService(limits: .pro()))
        await model.load()
        model.password = String(repeating: "p", count: ShareSheetModel.passwordLimit + 1)
        #expect(model.passwordTooLongMessage != nil)
        #expect(!model.canCreate)
        model.password = String(repeating: "p", count: ShareSheetModel.passwordLimit)
        #expect(model.canCreate)

        let long = makeModel(
            .query(title: "Long", sql: String(repeating: "x", count: ShareSheetModel.sqlLimit + 1), dialect: nil),
            service: FakeShareService()
        )
        await long.load()
        #expect(long.sqlTooLongMessage != nil)
        #expect(!long.canCreate)
    }

    // MARK: - Teams

    @Test("Share as a team sends its ID and the footer counts the team's links")
    func teamTarget() async throws {
        let model = makeModel(service: FakeShareService(limits: .pro(teams: [Self.acme, Self.closed])))
        await model.load()

        #expect(model.teams.map(\.id) == ["team_acme", "team_closed"])
        model.target = .team("team_acme")
        #expect(try #require(model.makeDraft()).teamID == "team_acme")
        #expect(model.footer == formatted("%1$@ · %2$lld of %3$lld links", "Acme", Int64(4), Int64(1_000)))

        model.target = .personal
        #expect(try #require(model.makeDraft()).teamID == nil)
    }

    @Test("A team at its cap shows that team's links, and switching back shows the form")
    func teamAtCap() async throws {
        let full = ShareTeam(id: "team_full", name: "Full", live: 1_000, liveLimit: 1_000, allowsPublicLinks: true)
        let service = FakeShareService(limits: .pro(teams: [full]))
        service.linksResult = .success([Self.link("shr_team")])
        let model = makeModel(service: service)
        await model.load()
        #expect(model.phase == .form)

        model.target = .team("team_full")
        #expect(model.phase == .atCap)
        #expect(model.atCapMessage == formatted("This team has %lld live links.", Int64(1_000)) + " "
            + formatted("Teams allow %lld. Revoke one to share another.", Int64(1_000)))
        try await waitUntil { !model.liveLinks.isEmpty }
        #expect(service.linkTeams.last == "team_full")

        model.target = .personal
        #expect(model.phase == .form)
    }

    // MARK: - Drafts

    @Test("A query share always shows its SQL and carries no snapshot")
    func queryDraft() async throws {
        let model = makeModel(service: FakeShareService())
        await model.load()
        model.title = "  Report  "
        model.note = "  "
        let draft = try #require(model.makeDraft())

        #expect(draft.kind == .query)
        #expect(draft.sql == "SELECT 1")
        #expect(draft.title == "Report")
        #expect(draft.note == nil)
        #expect(draft.hidesSQL == nil)
        #expect(draft.snapshot == nil)
        #expect(draft.dialect == "MySQL")
    }

    @Test("A result share carries Hide SQL, the loaded statement, and a snapshot cut to the plan's rows")
    func resultDraft() async throws {
        let model = makeModel(
            Self.resultRequest(rows: 1_200, total: 48_210, sql: "SELECT * FROM users LIMIT 1000"),
            service: FakeShareService(limits: .free())
        )
        await model.load()
        model.hidesSQL = true
        let draft = try #require(model.makeDraft())
        let snapshot = try #require(draft.snapshot)

        #expect(draft.kind == .result)
        #expect(draft.hidesSQL == true)
        #expect(draft.sql == "SELECT * FROM users LIMIT 1000")
        #expect(snapshot.rows.count == 1_000)
        #expect(snapshot.rowCount == 48_210)
        #expect(model.capNote == formatted("Shares the first %1$lld of %2$lld rows.", Int64(1_000), Int64(48_210)))
        #expect(model.previewRows.count == ShareSheetModel.previewRowCount)
    }

    @MainActor
    private final class Asked {
        var maxRows: [Int] = []
    }

    @Test("The loader is asked for the plan's rows")
    func loaderGetsMaxRows() async throws {
        let asked = Asked()
        let request = ShareRequest.result(title: "T", sql: "SELECT 1", dialect: nil) { maxRows in
            asked.maxRows.append(maxRows)
            return Self.source(rows: 2, total: .none, sql: "SELECT 1")
        }
        let model = makeModel(request, service: FakeShareService(limits: .pro()))
        await model.load()
        #expect(asked.maxRows == [10_000])
        #expect(model.phase == .form)
    }

    @Test("A result with no SQL to share sends its rows without Hide SQL")
    func resultWithoutSQL() async throws {
        let model = makeModel(Self.resultRequest(rows: 3, sql: ""), service: FakeShareService())
        await model.load()
        model.hidesSQL = true
        let draft = try #require(model.makeDraft())
        #expect(!model.hasSharedSQL)
        #expect(draft.sql.isEmpty)
        #expect(draft.hidesSQL == nil)
        #expect(draft.snapshot != nil)
    }

    @Test("A total nobody counted says the result is larger")
    func unknownTotalNote() async {
        let model = makeModel(Self.resultRequest(rows: 3, total: .some(nil)), service: FakeShareService())
        await model.load()
        #expect(model.capNote == formatted("Shares the first %lld rows of a larger result.", Int64(3)))
    }

    @Test("A result inside the limit has no cap note")
    func noCapNote() async {
        let model = makeModel(Self.resultRequest(rows: 3), service: FakeShareService())
        await model.load()
        #expect(model.capNote == nil)
    }

    @Test("Long fields are cut to the server's caps")
    func fieldCaps() async throws {
        let model = makeModel(service: FakeShareService(limits: .pro()))
        await model.load()
        model.title = String(repeating: "t", count: 300)
        model.note = String(repeating: "n", count: 3_000)
        let draft = try #require(model.makeDraft())
        #expect(draft.title.count == ShareSheetModel.titleLimit)
        #expect(draft.note?.count == ShareSheetModel.noteLimit)
    }

    // MARK: - Creating

    @Test("Creating copies the link and shows it")
    func createCopiesLink() async {
        let service = FakeShareService()
        let box = Box(signedIn: true)
        let model = makeModel(service: service, box: box)
        await model.load()
        await model.create()

        let url = URL(string: "https://s.tablepro.app/abc")!
        #expect(model.phase == .created(url))
        #expect(box.copied == [url.absoluteString])
        #expect(model.limits?.live == 4)
    }

    @Test("A second Create while the first is out sends nothing")
    func noDoubleSubmit() async throws {
        let service = FakeShareService()
        let gate = AsyncGate()
        service.createGate = gate
        let model = makeModel(service: service)
        await model.load()

        let first = Task { await model.create() }
        await gate.arrived(1)
        #expect(model.isCreating)
        #expect(!model.canCreate)
        await model.create()
        await gate.open()
        await first.value

        #expect(service.drafts.count == 1)
    }

    @Test("A create that answers after the sheet closed leaves the clipboard alone")
    func closedSheetKeepsClipboard() async throws {
        let service = FakeShareService()
        let gate = AsyncGate()
        service.createGate = gate
        let box = Box(signedIn: true)
        let model = makeModel(service: service, box: box)
        await model.load()

        let first = Task { await model.create() }
        await gate.arrived(1)
        model.close()
        await gate.open()
        await first.value

        #expect(box.copied.isEmpty)
        #expect(model.phase == .form)
    }

    @Test("Each refusal is worded for its code", arguments: [
        (ShareFailure.proRequired, "This option needs TablePro Pro."),
        (.teamSharingDisabled, "Public links are turned off for this team."),
        (.snapshotTooLarge, "This result is too large to share."),
        (.rateLimited, "Too many links just now. Try again in a moment."),
        (.offline, "You appear to be offline. Try again once you're connected."),
        (.server, "The link couldn't be created. Try again.")
    ])
    func refusalWording(failure: ShareFailure, english: String) async {
        let service = FakeShareService()
        service.createResult = .failure(failure)
        let model = makeModel(service: service)
        await model.load()
        await model.create()

        #expect(model.phase == .form)
        #expect(model.failureMessage == String(localized: String.LocalizationValue(english)))
    }

    @Test("Hitting the cap on create shows the live links")
    func createAtCap() async throws {
        let service = FakeShareService()
        service.limitsResults = [.success(.free(live: 4)), .success(.free(live: 5))]
        service.createResult = .failure(.limitReached)
        let model = makeModel(service: service)
        await model.load()
        await model.create()

        #expect(model.phase == .atCap)
    }

    @Test("A result too large to share cannot be created")
    func tooLargeBlocksCreate() async {
        let count = ShareSnapshotBuilder.maxColumns + 1
        let request = ShareRequest.result(
            title: "Wide",
            dialect: nil,
            source: ShareResultSource(
                columns: (0..<count).map { "c\($0)" },
                columnTypes: Array(repeating: .text(rawType: "text"), count: count),
                rows: [Array(repeating: .text("x"), count: count)],
                totalRowCount: 1,
                sql: "SELECT *"
            )
        )
        let model = makeModel(request, service: FakeShareService())
        await model.load()

        #expect(model.isSnapshotTooLarge)
        #expect(!model.canCreate)
    }

    // MARK: - At the cap

    @Test("At the cap the live links show oldest first, and revoking one brings the form back")
    func atCapRevoke() async throws {
        let service = FakeShareService(limits: .free(live: 5))
        service.linksResult = .success([Self.link("shr_new", at: 2), Self.link("shr_old", at: 1)])
        let model = makeModel(service: service)
        await model.load()

        #expect(model.phase == .atCap)
        #expect(model.atCapMessage == formatted("You have %lld live links.", Int64(5)) + " "
            + formatted("Free allows %lld. Revoke one to share another.", Int64(5)))
        #expect(model.showsProUpsell)
        try await waitUntil { model.liveLinks.map(\.id) == ["shr_old", "shr_new"] }

        await model.revoke(Self.link("shr_old", at: 1))
        #expect(service.revokedIDs == ["shr_old"])
        #expect(model.liveLinks.map(\.id) == ["shr_new"])
        #expect(model.limits?.live == 4)
        #expect(model.phase == .form)
    }

    @Test("Pro at its cap says how many Pro allows, with no upsell")
    func proAtCap() async {
        let service = FakeShareService(limits: .pro(live: 1_000))
        let model = makeModel(service: service)
        await model.load()
        #expect(model.phase == .atCap)
        #expect(model.atCapMessage == formatted("You have %lld live links.", Int64(1_000)) + " "
            + formatted("Pro allows %lld. Revoke one to share another.", Int64(1_000)))
        #expect(!model.showsProUpsell)
    }

    @Test("A revoke the server refuses keeps the link and says so, and a later one clears the message")
    func revokeFailureThenSuccess() async throws {
        let service = FakeShareService(limits: .free(live: 6))
        let first = Self.link("shr_1", at: 1)
        let second = Self.link("shr_2", at: 2)
        service.linksResult = .success([first, second])
        service.revokeFailure = .offline
        let model = makeModel(service: service)
        await model.load()
        try await waitUntil { model.liveLinks.count == 2 }

        await model.revoke(first)
        #expect(model.liveLinks.count == 2)
        #expect(model.linksFailure != nil)

        service.revokeFailure = nil
        await model.revoke(first)
        #expect(model.linksFailure == nil)
        #expect(model.liveLinks == [second])
    }

    @Test("A list that failed to load comes back on retry")
    func linksRetry() async throws {
        let service = FakeShareService(limits: .free(live: 5))
        service.linksResult = .failure(.offline)
        let model = makeModel(service: service)
        await model.load()
        try await waitUntil { model.linksFailure != nil }

        service.linksResult = .success([Self.link("shr_1")])
        await model.loadLiveLinks()
        #expect(model.linksFailure == nil)
        #expect(model.liveLinks.map(\.id) == ["shr_1"])
    }

    // MARK: - Secret warnings

    @Test("A secret in the SQL warns while the SQL is shown and not once it is hidden")
    func secretWarnings() async throws {
        let model = makeModel(
            Self.resultRequest(sql: "SELECT * FROM users WHERE password = 'hunter2'"),
            service: FakeShareService()
        )
        await model.load()
        try await waitUntil { !model.secretWarnings.isEmpty }

        #expect(model.secretWarnings.count == 1)
        model.hidesSQL = true
        #expect(model.secretWarnings.isEmpty)
        #expect(model.columnWarning == String(
            format: String(localized: "Some columns may hold secrets: %@."),
            ListFormatter.localizedString(byJoining: ["api_key"])
        ))
    }
}
