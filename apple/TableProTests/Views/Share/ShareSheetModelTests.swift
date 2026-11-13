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

    private static func resultRequest(rows: Int = 3, total: Int? = nil, sql: String = "SELECT id FROM users") -> ShareRequest {
        .result(
            title: "Users",
            sql: sql,
            dialect: "PostgreSQL",
            source: ShareResultSource(
                columns: ["id", "api_key"],
                columnTypes: [.integer(rawType: "int8"), .text(rawType: "text")],
                rows: (0..<rows).map { [.text(String($0)), .text("k\($0)")] },
                totalRowCount: total ?? rows
            )
        )
    }

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
        #expect(free.footer == String(
            format: String(localized: "Free · %1$@ of %2$@ links · first %3$@ rows"),
            3.formatted(), 5.formatted(), 1_000.formatted()
        ))

        let pro = makeModel(service: FakeShareService(limits: .pro(live: 12)))
        await pro.load()
        #expect(pro.footer == String(format: String(localized: "Pro · %@ links"), 12.formatted()))

        let single = makeModel(service: FakeShareService(limits: .pro(live: 1)))
        await single.load()
        #expect(single.footer == String(format: String(localized: "Pro · %@ link"), 1.formatted()))
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

    @Test("A result share carries Hide SQL and a snapshot cut to the plan's rows")
    func resultDraft() async throws {
        let model = makeModel(Self.resultRequest(rows: 1_200, total: 48_210), service: FakeShareService(limits: .free()))
        await model.load()
        model.hidesSQL = true
        let draft = try #require(model.makeDraft())
        let snapshot = try #require(draft.snapshot)

        #expect(draft.kind == .result)
        #expect(draft.hidesSQL == true)
        #expect(snapshot.rows.count == 1_000)
        #expect(snapshot.rowCount == 48_210)
        #expect(model.capNote == String(
            format: String(localized: "Shares the first %1$@ of %2$@ rows."),
            1_000.formatted(), 48_210.formatted()
        ))
        #expect(model.previewRows.count == ShareSheetModel.previewRowCount)
    }

    @Test("Pro keeps up to 10,000 rows")
    func proRowLimit() async throws {
        let model = makeModel(Self.resultRequest(rows: 12_000), service: FakeShareService(limits: .pro()))
        await model.load()
        #expect(try #require(model.makeDraft()?.snapshot).rows.count == 10_000)
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
            sql: "SELECT *",
            dialect: nil,
            source: ShareResultSource(
                columns: (0..<count).map { "c\($0)" },
                columnTypes: Array(repeating: .text(rawType: "text"), count: count),
                rows: [Array(repeating: .text("x"), count: count)],
                totalRowCount: 1
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
        let older = ShareLink(id: "shr_old", title: "Old", kind: .query, createdAt: Date(timeIntervalSince1970: 1), expiresAt: nil)
        let newer = ShareLink(id: "shr_new", title: "New", kind: .result, createdAt: Date(timeIntervalSince1970: 2), expiresAt: nil)
        service.linksResult = .success([newer, older])
        let model = makeModel(service: service)
        await model.load()

        #expect(model.phase == .atCap)
        #expect(model.atCapMessage == String(
            format: String(localized: "You have %@ live links, the Free limit. Revoke one to share another."),
            5.formatted()
        ))
        try await waitUntil { model.liveLinks.map(\.id) == ["shr_old", "shr_new"] }

        await model.revoke(older)
        #expect(service.revokedIDs == ["shr_old"])
        #expect(model.liveLinks.map(\.id) == ["shr_new"])
        #expect(model.limits?.live == 4)
        #expect(model.phase == .form)
    }

    @Test("A revoke the server refuses keeps the link and says so")
    func revokeFailureKeepsLink() async throws {
        let service = FakeShareService(limits: .free(live: 5))
        let link = ShareLink(id: "shr_1", title: "One", kind: .query, createdAt: Date(), expiresAt: nil)
        service.linksResult = .success([link])
        service.revokeFailure = .offline
        let model = makeModel(service: service)
        await model.load()
        try await waitUntil { !model.liveLinks.isEmpty }

        await model.revoke(link)
        #expect(model.liveLinks == [link])
        #expect(model.phase == .atCap)
        #expect(model.linksFailure != nil)
    }

    // MARK: - Secret warnings

    @Test("A secret in the SQL warns while the SQL is shown and not once it is hidden")
    func secretWarnings() async {
        let model = makeModel(
            Self.resultRequest(sql: "SELECT * FROM users WHERE password = 'hunter2'"),
            service: FakeShareService()
        )
        await model.load()

        #expect(model.secretWarnings.count == 1)
        model.hidesSQL = true
        #expect(model.secretWarnings.isEmpty)
        #expect(model.columnWarning == String(
            format: String(localized: "Some columns may hold secrets: %@."),
            ListFormatter.localizedString(byJoining: ["api_key"])
        ))
    }
}
