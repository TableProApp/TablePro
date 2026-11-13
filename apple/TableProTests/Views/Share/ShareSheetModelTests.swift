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

    private func needsPro(_ action: String.LocalizationValue) -> String {
        String(localized: "This option needs TablePro Pro.") + " " + String(localized: action)
    }

    @Test("Free defaults to 30 days, and Never, a password or downloads turned off hold Create with the reason, never dropped")
    func freeGating() async throws {
        let model = makeModel(service: FakeShareService(limits: .free()))
        await model.load()

        #expect(model.expiry == .thirtyDays)
        #expect(!model.isAvailable(.never))
        #expect(model.isAvailable(.oneDay))
        #expect(model.canCreate)

        model.expiry = .never
        #expect(model.expiryMessage == needsPro("Choose another expiry to create the link."))
        model.password = "secret"
        #expect(model.passwordMessage == needsPro("Clear the password to create the link."))
        model.allowsDownload = false
        #expect(model.downloadMessage == needsPro("Turn downloads back on to create the link."))
        #expect(!model.canCreate)
        #expect(model.makeDraft() == nil)

        model.expiry = .sevenDays
        model.password = ""
        model.allowsDownload = true
        #expect(model.canCreate)
        let draft = try #require(model.makeDraft())
        #expect(draft.expiry == .sevenDays)
        #expect(draft.password == nil)
        #expect(draft.allowsDownload == nil)
    }

    @Test("A reload as Free keeps the typed password and Never, and holds Create until the person changes them")
    func downgradeKeepsChoices() async throws {
        let service = FakeShareService()
        service.limitsResults = [.success(.pro()), .success(.free())]
        service.createResult = .failure(.limitReached)
        let model = makeModel(service: service)
        await model.load()
        #expect(model.expiry == .never)
        model.password = "hunter2"

        await model.create()
        #expect(model.limits?.plan == .free)
        #expect(model.phase == .form)
        #expect(model.password == "hunter2")
        #expect(model.expiry == .never)
        #expect(model.passwordMessage == needsPro("Clear the password to create the link."))
        #expect(model.expiryMessage == needsPro("Choose another expiry to create the link."))
        #expect(!model.canCreate)

        model.password = ""
        model.expiry = .thirtyDays
        #expect(model.canCreate)
    }

    @Test("A password goes without leading and trailing spaces and tabs, and one of only those holds Create")
    func passwordWhitespace() async throws {
        let model = makeModel(service: FakeShareService(limits: .pro()))
        await model.load()

        model.password = " \thunter 2\t "
        #expect(try #require(model.makeDraft()).password == "hunter 2")

        model.password = " \t "
        #expect(model.passwordMessage == String(localized: "A password can't be only spaces or tabs."))
        #expect(!model.canCreate)
        #expect(model.makeDraft() == nil)
    }

    @Test("SQL is held to 256 KiB of UTF-8, not 262,144 characters")
    func sqlLimitCountsBytes() async {
        let atLimit = makeModel(
            .query(title: "Q", sql: String(repeating: "\u{E9}", count: ShareSheetModel.sqlLimit / 2), dialect: nil),
            service: FakeShareService()
        )
        await atLimit.load()
        #expect(atLimit.sqlTooLongMessage == nil)
        #expect(atLimit.canCreate)

        let over = makeModel(
            .query(title: "Q", sql: String(repeating: "\u{E9}", count: ShareSheetModel.sqlLimit / 2 + 1), dialect: nil),
            service: FakeShareService()
        )
        await over.load()
        #expect(over.sqlTooLongMessage == String(
            format: String(localized: "This query is too long to share. A link holds up to %@ of SQL."),
            ByteCountFormatter.string(fromByteCount: Int64(ShareSheetModel.sqlLimit), countStyle: .memory)
        ))
        #expect(!over.canCreate)
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
        #expect(model.passwordMessage != nil)
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

    @Test("A cell past the server's cap makes the result too large to share")
    func tooLargeBlocksCreate() async {
        let request = ShareRequest.result(
            title: "Huge",
            dialect: nil,
            source: ShareResultSource(
                columns: ["body"],
                columnTypes: [.text(rawType: "text")],
                rows: [[.text(String(repeating: "x", count: ShareSnapshotBuilder.maxCellBytes))]],
                totalRowCount: 1,
                sql: "SELECT *"
            )
        )
        let model = makeModel(request, service: FakeShareService())
        await model.load()

        #expect(model.isSnapshotTooLarge)
        #expect(!model.canCreate)
    }

    @Test("More than 100 kept columns share the first 100, say so before and after, and count only those sent")
    func columnCap() async throws {
        let count = ShareSnapshotBuilder.maxColumns + 2
        let names = (0..<count).map { "c\($0)" }
        let request = ShareRequest.result(
            title: "Wide",
            dialect: nil,
            source: ShareResultSource(
                columns: names,
                columnTypes: Array(repeating: .text(rawType: "text"), count: count),
                rows: [Array(repeating: .text("x"), count: count)],
                totalRowCount: 1,
                sql: "SELECT *"
            )
        )
        let model = makeModel(request, service: FakeShareService())
        await model.load()
        let capNote = formatted("Shares the first %lld columns.", Int64(ShareSnapshotBuilder.maxColumns))

        #expect(model.canCreate)
        #expect(model.columnCapNote == capNote)
        #expect(model.previewColumns.map(\.name) == Array(names.prefix(ShareSnapshotBuilder.maxColumns)))
        model.setAction(.mask, forColumn: count - 1)
        #expect(model.columnSummary == formatted("%1$lld columns masked, %2$lld removed.", Int64(0), Int64(0)))

        model.setAction(.remove, forColumn: 0)
        try await waitUntil { model.canCreate }
        #expect(model.columnCapNote == capNote)
        #expect(model.previewColumns.map(\.name) == Array(names.dropFirst().prefix(ShareSnapshotBuilder.maxColumns)))
        await model.create()
        #expect(model.createdColumnCapNote == formatted("The link shares the first %lld columns.", Int64(ShareSnapshotBuilder.maxColumns)))

        let narrow = makeModel(Self.peopleRequest(), service: FakeShareService())
        await narrow.load()
        #expect(narrow.columnCapNote == nil)
        await narrow.create()
        #expect(narrow.createdColumnCapNote == nil)
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
    }

    @Test("A column that may hold secrets warns only once it is sent as it is")
    func columnWarningForKeptColumns() async throws {
        let model = makeModel(Self.resultRequest(), service: FakeShareService())
        await model.load()
        #expect(model.columns.map(\.action) == [.keep, .mask])
        #expect(model.columnWarning == nil)

        model.setAction(.keep, forColumn: 1)
        #expect(model.columnWarning == String(
            format: String(localized: "Some columns may hold secrets: %@."),
            ListFormatter.localizedString(byJoining: ["api_key"])
        ))
    }

    // MARK: - Columns

    private static func peopleRequest(sql: String = "SELECT * FROM people") -> ShareRequest {
        .result(title: "People", dialect: "PostgreSQL", source: peopleSource(sql: sql))
    }

    private static func peopleSource(sql: String = "SELECT * FROM people") -> ShareResultSource {
        ShareResultSource(
            columns: ["id", "email", "ip", "note"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text"), .text(rawType: "inet"), .text(rawType: "text")],
            rows: [
                [.text("1"), .text("jane@example.com"), .text("j•••@x.io"), .text("hello")],
                [.text("2"), .text("john@example.com"), .text("a1b2c3d4e5f6"), .text("world")]
            ],
            totalRowCount: 2,
            sql: sql,
            masks: ColumnMasks(styles: [2: .hash])
        )
    }

    @Test("Rows read again for a new row limit keep the column choices, and the snapshot follows them")
    func reloadKeepsChoices() async throws {
        let service = FakeShareService()
        service.limitsResults = [.success(.free()), .success(.pro())]
        service.createResult = .failure(.limitReached)
        let asked = Asked()
        let request = ShareRequest.result(title: "People", sql: "SELECT * FROM people", dialect: nil) { maxRows in
            asked.maxRows.append(maxRows)
            return Self.peopleSource()
        }
        let model = makeModel(request, service: service)
        await model.load()
        model.setAction(.mask, forColumn: 0)
        model.setAction(.remove, forColumn: 3)
        try await waitUntil { model.canCreate }

        await model.create()
        #expect(asked.maxRows == [1_000, 10_000])
        #expect(model.columns.map(\.action) == [.mask, .mask, .mask, .remove])
        try await waitUntil { model.canCreate }
        let snapshot = try #require(model.makeDraft()?.snapshot)
        #expect(snapshot.columns.map(\.name) == ["id", "email", "ip"])
        #expect(snapshot.columns.map(\.masked) == [.full, .email, .hash])
    }

    @Test("Columns start from the rules and the detectors, and the snapshot sends the values as the preview shows them")
    func columnDefaults() async throws {
        let model = makeModel(Self.peopleRequest(), service: FakeShareService())
        await model.load()

        #expect(model.columns.map(\.action) == [.keep, .mask, .mask, .keep])
        #expect(model.columns.map(\.style) == [.full, .email, .hash, .full])
        #expect(model.hasDetections)
        #expect(model.columnSummary == formatted("%1$lld columns masked, %2$lld removed.", Int64(2), Int64(0)))
        let snapshot = try #require(model.makeDraft()?.snapshot)
        #expect(snapshot.columns.map(\.masked) == [nil, .email, .hash, nil])
        #expect(snapshot.rows.first == [.number("1"), .string("j•••@example.com"), .string("j•••@x.io"), .string("hello")])
        #expect(model.previewRows.first == snapshot.rows.first)
    }

    @Test("A rule-masked column cannot be kept and takes only a stricter style")
    func ruleMaskedColumnStaysMasked() async {
        let model = makeModel(Self.peopleRequest(), service: FakeShareService())
        await model.load()

        model.setAction(.keep, forColumn: 2)
        model.setStyle(.email, forColumn: 2)
        #expect(model.columns[2].action == .mask)
        #expect(model.columns[2].style == .hash)
        #expect(model.canCreate)
    }

    @Test("A change to the columns holds Create until the snapshot is rebuilt with it")
    func columnChangeRebuilds() async throws {
        let model = makeModel(Self.peopleRequest(), service: FakeShareService())
        await model.load()

        model.setAction(.remove, forColumn: 3)
        model.setAction(.keep, forColumn: 1)
        model.setStyle(.null, forColumn: 2)
        #expect(!model.canCreate)
        #expect(model.makeDraft() == nil)

        try await waitUntil { model.canCreate }
        let snapshot = try #require(model.makeDraft()?.snapshot)
        #expect(snapshot.columns.map(\.name) == ["id", "email", "ip"])
        #expect(snapshot.columns.map(\.masked) == [nil, nil, .null])
        #expect(snapshot.rows.first == [.number("1"), .string("jane@example.com"), .null])
        #expect(model.columnSummary == formatted("%1$lld columns masked, %2$lld removed.", Int64(1), Int64(1)))
    }

    @Test("Removing every column says so and blocks Create")
    func everyColumnRemoved() async throws {
        let model = makeModel(Self.peopleRequest(), service: FakeShareService())
        await model.load()
        for index in 0..<4 {
            model.setAction(.remove, forColumn: index)
        }
        try await waitUntil { model.isEveryColumnRemoved }
        #expect(!model.canCreate)
    }

    @Test("Personal data in the SQL suggests Hide SQL until it is on, and never for a query share")
    func hideSQLSuggestion() async throws {
        let model = makeModel(
            Self.peopleRequest(sql: "SELECT * FROM people WHERE email = 'jane@example.com'"),
            service: FakeShareService()
        )
        await model.load()
        try await waitUntil { model.hideSQLSuggestion != nil }
        #expect(model.hideSQLSuggestion == String(
            format: String(localized: "This query contains what looks like personal data (%@). Turn on Hide SQL to keep the query private."),
            ListFormatter.localizedString(byJoining: [SensitiveValueKind.email.displayName])
        ))
        model.hidesSQL = true
        #expect(model.hideSQLSuggestion == nil)

        let query = makeModel(.query(title: "Q", sql: "SELECT 'jane@example.com'", dialect: nil), service: FakeShareService())
        await query.load()
        try await waitUntil { !query.sqlPersonalData.isEmpty }
        #expect(query.hideSQLSuggestion == nil)
    }

    // MARK: - The rows changing under the sheet

    private static func notesSource(masked: Bool) -> ShareResultSource {
        ShareResultSource(
            columns: ["id", "notes"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text")],
            rows: [[.text("1"), .text(masked ? "••••" : "hello")]],
            totalRowCount: 1,
            sql: "SELECT id, notes FROM people",
            masks: masked ? ColumnMasks(styles: [1: .full]) : .none
        )
    }

    @Test("A rule saved while the sheet is open reads the rows again, and Create waits for them")
    func ruleSavedRereadsTheRows() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let asked = Asked()
        let request = ShareRequest.result(
            title: "People", sql: "SELECT id, notes FROM people", dialect: nil, sourceChanges: changes.eraseToAnyPublisher()
        ) { maxRows in
            asked.maxRows.append(maxRows)
            return Self.notesSource(masked: asked.maxRows.count > 1)
        }
        let model = makeModel(request, service: FakeShareService())
        await model.load()
        #expect(model.canCreate)
        model.setAction(.remove, forColumn: 0)
        try await waitUntil { model.canCreate }

        changes.send()
        #expect(!model.canCreate)
        #expect(model.makeDraft() == nil)
        try await waitUntil { model.canCreate }

        #expect(asked.maxRows == [1_000, 1_000])
        #expect(model.columns.map(\.action) == [.remove, .mask])
        #expect(model.columns.map(\.ruleStyle) == [nil, .full])
        let snapshot = try #require(model.makeDraft()?.snapshot)
        #expect(snapshot.columns.map(\.masked) == [.full])
        #expect(snapshot.rows == [[.string("••••")]])
    }

    @Test("A rule saved during a reload as Free reads the rows again at the Free limit, not the Pro one")
    func ruleSavedDuringAFreeReloadUsesItsLimit() async throws {
        let service = FakeShareService()
        service.limitsResults = [.success(.pro()), .success(.free())]
        service.createResult = .failure(.limitReached)
        let changes = PassthroughSubject<Void, Never>()
        let asked = Asked()
        let freeReadHeld = AsyncGate()
        let request = ShareRequest.result(
            title: "Users", sql: "SELECT id FROM users", dialect: nil, sourceChanges: changes.eraseToAnyPublisher()
        ) { maxRows in
            asked.maxRows.append(maxRows)
            if asked.maxRows.count == 2 {
                await freeReadHeld.wait()
            }
            return Self.source(rows: 1_200, total: 48_210, sql: "SELECT id FROM users")
        }
        let model = makeModel(request, service: service)
        await model.load()

        let create = Task { await model.create() }
        await freeReadHeld.arrived(1)
        changes.send()
        try await waitUntil { asked.maxRows.count == 3 }
        await freeReadHeld.open()
        await create.value
        // Never stays picked after the reload as Free, and holds Create until changed.
        model.expiry = .thirtyDays
        try await waitUntil { model.canCreate }

        #expect(asked.maxRows == [10_000, 1_000, 1_000])
        #expect(model.makeDraft()?.snapshot?.rows.count == 1_000)
    }

    @Test("A result no longer open says why Create is off")
    func resultGone() async {
        let request = ShareRequest.result(title: "Gone", sql: "SELECT 1", dialect: nil) { _ in nil }
        let model = makeModel(request, service: FakeShareService())
        await model.load()

        #expect(model.phase == .form)
        #expect(model.resultGoneMessage == String(localized: "This result is no longer open, so there are no rows to share."))
        #expect(!model.canCreate)
    }

    @Test("Counts read with the user's digit grouping, as PLAN 6 writes them")
    func countsAreGrouped() async {
        let free = makeModel(Self.resultRequest(rows: 1_200, total: 48_210), service: FakeShareService(limits: .free()))
        await free.load()
        #expect(free.footer == formatted("Free · %1$lld of %2$lld links · first %3$lld rows", Int64(3), Int64(5), Int64(1_000)))
        #expect(free.footer?.contains(1_000.formatted()) == true)
        #expect(free.capNote?.contains(1_000.formatted()) == true)
        #expect(free.capNote?.contains(48_210.formatted()) == true)
    }
}
