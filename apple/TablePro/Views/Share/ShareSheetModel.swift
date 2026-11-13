//
//  ShareSheetModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class ShareSheetModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case loading
        case loadFailed(String)
        case emailUnverified
        case sharingDisabled
        case atCap
        case form
        case created(URL)
    }

    // The server's field caps (api/v2.json, CreateShareBody), counted in Unicode scalars as the server counts them.
    static let titleLimit = 200
    static let noteLimit = 2_000
    static let passwordLimit = 128
    static let sqlLimit = 262_144
    static let previewRowCount = 5

    let request: ShareRequest

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var limits: ShareLimits?
    @Published private(set) var source: ShareResultSource?
    @Published private(set) var snapshot: ShareSnapshotOutcome?
    @Published private(set) var liveLinks: [ShareLink] = []
    @Published private(set) var isLoadingLinks = false
    @Published private(set) var linksFailure: String?
    @Published private(set) var revokingLinkIDs: Set<String> = []
    @Published private(set) var isCreating = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var sqlSecretKinds: [SecretKind] = []
    @Published private(set) var sqlPersonalData: [SensitiveValueKind] = []
    @Published private(set) var columns: [ShareColumnChoice] = []

    @Published var title: String
    @Published var note = ""
    @Published var expiry: ShareExpiry = .thirtyDays
    @Published var hidesSQL = false
    @Published var password = ""
    @Published var allowsDownload = true
    @Published var target: ShareTarget = .personal {
        didSet {
            guard target != oldValue else { return }
            settlePhase()
        }
    }

    private let service: any ShareService
    private let isSignedIn: @MainActor () -> Bool
    private let copyToClipboard: @MainActor (String) -> Void
    private var signInObservation: AnyCancellable?
    private var appliedDefaults = false
    private var sourceMaxRows: Int?
    // The column choices the snapshot was built with; a snapshot built for others is never sent.
    private var builtColumns: [ShareColumnChoice]?
    private var rebuild: Task<Void, Never>?
    private var scannedSQL: String?
    private var work: [Task<Void, Never>] = []
    private var isClosed = false

    init(
        request: ShareRequest,
        service: any ShareService,
        isSignedIn: @escaping @MainActor () -> Bool,
        signInChanges: AnyPublisher<Bool, Never>,
        copyToClipboard: @escaping @MainActor (String) -> Void
    ) {
        self.request = request
        self.service = service
        self.isSignedIn = isSignedIn
        self.copyToClipboard = copyToClipboard
        self.title = String(String.UnicodeScalarView(request.title.unicodeScalars.prefix(Self.titleLimit)))
        signInObservation = signInChanges
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, self.phase == .signedOut else { return }
                self.track(Task { await self.load() })
            }
        scanSQL(request.sql)
    }

    // The sheet went away: nothing it started may finish into a closed sheet or onto the clipboard.
    func close() {
        isClosed = true
        work.forEach { $0.cancel() }
        work.removeAll()
    }

    private func track(_ task: Task<Void, Never>) {
        work.removeAll { $0.isCancelled }
        work.append(task)
    }

    // MARK: - Loading

    func load() async {
        guard isSignedIn() else {
            phase = .signedOut
            return
        }
        if limits == nil {
            phase = .loading
        }
        do throws(ShareFailure) {
            let limits = try await service.limits()
            await loadSource(maxRows: limits.maxRows)
            guard !isClosed else { return }
            apply(limits)
        } catch .signedOut {
            phase = .signedOut
        } catch .canceled {
            return
        } catch {
            if limits == nil {
                phase = .loadFailed(Self.loadMessage(error))
            } else {
                failureMessage = error.message
            }
        }
    }

    static func loadMessage(_ failure: ShareFailure) -> String {
        if failure == .offline, let message = failure.message {
            return message
        }
        return String(localized: "Sharing isn't available right now. Try again.")
    }

    private func apply(_ limits: ShareLimits) {
        self.limits = limits
        if !appliedDefaults {
            appliedDefaults = true
            expiry = limits.allows(limits.defaultExpiry) ? limits.defaultExpiry : (limits.expiries.first ?? .thirtyDays)
        }
        if let teamID = target.teamID, limits.team(teamID)?.allowsPublicLinks != true {
            // Settles the phase through didSet.
            target = .personal
            return
        }
        settlePhase()
    }

    private func settlePhase() {
        guard let limits else { return }
        if !limits.emailVerified {
            phase = .emailUnverified
        } else if limits.sharingDisabled {
            phase = .sharingDisabled
        } else if isTargetAtCap {
            phase = .atCap
            liveLinks = []
            linksFailure = nil
            track(Task { await loadLiveLinks() })
        } else if phase != .form {
            phase = .form
        }
    }

    // Up to 10,000 rows of 100 columns: read, scanned and built off the main actor, once per row limit.
    private func loadSource(maxRows: Int) async {
        guard let load = request.loadResult, sourceMaxRows != maxRows else { return }
        guard let loaded = await load(maxRows), !Task.isCancelled, !isClosed else { return }
        source = loaded
        sourceMaxRows = maxRows
        scanSQL(loaded.sql)
        let detect = Task.detached(priority: .userInitiated) {
            ShareColumnChoice.defaults(for: loaded, maxRows: maxRows)
        }
        let choices = await withTaskCancellationHandler {
            await detect.value
        } onCancel: {
            detect.cancel()
        }
        guard let choices, !isClosed else { return }
        columns = choices
        await buildSnapshot()
    }

    private func buildSnapshot() async {
        guard let source, let maxRows = sourceMaxRows else { return }
        let choices = columns
        let shared = choices.compactMap(\.sharedColumn)
        let build = Task.detached(priority: .userInitiated) {
            ShareSnapshotBuilder.build(source, maxRows: maxRows, columns: shared)
        }
        let built = await withTaskCancellationHandler {
            await build.value
        } onCancel: {
            build.cancel()
        }
        guard let built, !isClosed, choices == columns else { return }
        snapshot = built
        builtColumns = choices
    }

    private func scanSQL(_ sql: String) {
        guard sql != scannedSQL else { return }
        scannedSQL = sql
        let scan = Task.detached(priority: .utility) {
            (SecretScanner.scanSQL(sql), SensitiveDataDetector.personalData(inSQL: sql))
        }
        track(Task { [weak self] in
            let (hits, personalData) = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard let self, self.scannedSQL == sql else { return }
            var kinds: [SecretKind] = []
            for hit in hits where !kinds.contains(hit.kind) {
                kinds.append(hit.kind)
            }
            self.sqlSecretKinds = kinds
            self.sqlPersonalData = personalData
        })
    }

    // MARK: - Columns

    func setAction(_ action: ShareColumnChoice.Action, forColumn index: Int) {
        update(column: index) { $0.choosing(action) }
    }

    func setStyle(_ style: MaskingStyle, forColumn index: Int) {
        update(column: index) { $0.choosing(style: style) }
    }

    private func update(column index: Int, _ change: (ShareColumnChoice) -> ShareColumnChoice?) {
        guard let position = columns.firstIndex(where: { $0.index == index }),
              let changed = change(columns[position]), changed != columns[position]
        else { return }
        columns[position] = changed
        rebuild?.cancel()
        let task = Task { await buildSnapshot() }
        rebuild = task
        track(task)
    }

    func loadLiveLinks() async {
        guard !isLoadingLinks else { return }
        isLoadingLinks = true
        defer { isLoadingLinks = false }
        let teamID = target.teamID
        do throws(ShareFailure) {
            let links = try await service.liveLinks(teamID: teamID)
            guard target.teamID == teamID else { return }
            liveLinks = links.sorted { $0.createdAt < $1.createdAt }
            linksFailure = nil
        } catch .canceled {
            return
        } catch {
            linksFailure = Self.loadMessage(error)
        }
    }

    // MARK: - At the cap

    var isTargetAtCap: Bool {
        switch target {
        case .personal: limits?.isAtCap ?? false
        case .team(let id): limits?.team(id)?.isAtCap ?? false
        }
    }

    func revoke(_ link: ShareLink) async {
        guard !revokingLinkIDs.contains(link.id) else { return }
        revokingLinkIDs.insert(link.id)
        defer { revokingLinkIDs.remove(link.id) }
        do throws(ShareFailure) {
            try await service.revoke(id: link.id)
        } catch .notFound, .revoked, .removed {
            // Already gone elsewhere: its slot is free either way.
        } catch .canceled {
            return
        } catch {
            linksFailure = Self.loadMessage(error)
            return
        }
        linksFailure = nil
        liveLinks.removeAll { $0.id == link.id }
        adjustLive(by: -1)
        if !isTargetAtCap, phase == .atCap {
            phase = .form
        }
    }

    private func adjustLive(by delta: Int) {
        guard let current = limits else { return }
        var updated = current
        switch target {
        case .personal:
            updated = ShareLimits(
                plan: current.plan,
                live: max(0, current.live + delta),
                liveLimit: current.liveLimit,
                maxRows: current.maxRows,
                expiries: current.expiries,
                defaultExpiry: current.defaultExpiry,
                allowsPassword: current.allowsPassword,
                allowsDisablingDownload: current.allowsDisablingDownload,
                allowsTeamLinks: current.allowsTeamLinks,
                emailVerified: current.emailVerified,
                sharingDisabled: current.sharingDisabled,
                teams: current.teams
            )
        case .team(let id):
            guard let index = current.teams.firstIndex(where: { $0.id == id }) else { return }
            updated.teams[index].live = max(0, current.teams[index].live + delta)
        }
        limits = updated
    }

    // MARK: - Creating

    var isSnapshotTooLarge: Bool {
        snapshot == .tooLarge
    }

    var isEveryColumnRemoved: Bool {
        snapshot == .noColumns && builtColumns == columns
    }

    // Also while a change to the columns is rebuilding the snapshot, so Create never sends values masked the old way.
    var isPreparingRows: Bool {
        request.kind == .result && (snapshot == nil || builtColumns != columns)
    }

    var sharedSQL: String {
        source?.sql ?? request.sql
    }

    // A table view the host cannot write as SQL shares its rows alone.
    var hasSharedSQL: Bool {
        !sharedSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sqlTooLongMessage: String? {
        guard sharedSQL.unicodeScalars.count > Self.sqlLimit else { return nil }
        return String(
            format: String(localized: "This query is too long to share. A link holds up to %lld characters."),
            locale: .current,
            Int64(Self.sqlLimit)
        )
    }

    var passwordTooLongMessage: String? {
        guard password.unicodeScalars.count > Self.passwordLimit else { return nil }
        return String(
            format: String(localized: "A password can be up to %lld characters."),
            locale: .current,
            Int64(Self.passwordLimit)
        )
    }

    var canCreate: Bool {
        phase == .form && !isCreating && !isSnapshotTooLarge && !isEveryColumnRemoved && !isPreparingRows
            && sqlTooLongMessage == nil && passwordTooLongMessage == nil
    }

    func create() async {
        guard canCreate, let draft = makeDraft() else { return }
        isCreating = true
        failureMessage = nil
        defer { isCreating = false }
        do throws(ShareFailure) {
            let created = try await service.create(draft)
            guard !isClosed else { return }
            copyToClipboard(created.url.absoluteString)
            adjustLive(by: 1)
            phase = .created(created.url)
        } catch .limitReached {
            await load()
        } catch .signedOut {
            phase = .signedOut
        } catch .emailUnverified {
            phase = .emailUnverified
        } catch .sharingDisabled {
            phase = .sharingDisabled
        } catch {
            failureMessage = error.message
        }
    }

    func makeDraft() -> ShareDraft? {
        guard let limits else { return nil }
        let snapshotValue: ShareSnapshot?
        switch (request.kind, snapshot) {
        case (.result, .snapshot(let built)) where builtColumns == columns:
            snapshotValue = built
        case (.result, _):
            return nil
        case (.query, _):
            snapshotValue = nil
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesPassword = limits.allowsPassword && !password.isEmpty
        return ShareDraft(
            kind: request.kind,
            sql: sharedSQL,
            title: Self.clipped(title.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.titleLimit),
            note: trimmedNote.isEmpty ? nil : Self.clipped(trimmedNote, to: Self.noteLimit),
            dialect: request.dialect,
            expiry: limits.allows(expiry) ? expiry : limits.defaultExpiry,
            hidesSQL: request.kind == .result && hasSharedSQL ? hidesSQL : nil,
            allowsDownload: limits.allowsDisablingDownload && !allowsDownload ? false : nil,
            password: usesPassword ? password : nil,
            teamID: target.teamID,
            snapshot: snapshotValue
        )
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    func copyLink() {
        guard case .created(let url) = phase else { return }
        copyToClipboard(url.absoluteString)
    }

    // MARK: - What the sheet shows

    var isResult: Bool {
        request.kind == .result
    }

    var isPro: Bool {
        limits?.plan == .pro
    }

    var teams: [ShareTeam] {
        limits?.teams ?? []
    }

    func isAvailable(_ expiry: ShareExpiry) -> Bool {
        limits?.allows(expiry) ?? false
    }

    var previewColumns: [ShareSnapshot.Column] {
        guard case .snapshot(let built) = snapshot else { return [] }
        return built.columns
    }

    var previewRows: [[ShareCell]] {
        guard case .snapshot(let built) = snapshot else { return [] }
        return Array(built.rows.prefix(Self.previewRowCount))
    }

    var capNote: String? {
        guard case .snapshot(let built) = snapshot, built.isTruncated else { return nil }
        guard let total = built.rowCount else {
            return String(
                format: String(localized: "Shares the first %lld rows of a larger result."),
                locale: .current,
                Int64(built.rows.count)
            )
        }
        return String(
            format: String(localized: "Shares the first %1$lld of %2$lld rows."),
            locale: .current,
            Int64(built.rows.count),
            Int64(total)
        )
    }

    var footer: String? {
        guard let limits else { return nil }
        if let teamID = target.teamID, let team = limits.team(teamID) {
            return String(
                format: String(localized: "%1$@ · %2$lld of %3$lld links"),
                locale: .current,
                team.name,
                Int64(team.live),
                Int64(team.liveLimit)
            )
        }
        switch limits.plan {
        case .free:
            return String(
                format: String(localized: "Free · %1$lld of %2$lld links · first %3$lld rows"),
                locale: .current,
                Int64(limits.live),
                Int64(limits.liveLimit),
                Int64(limits.maxRows)
            )
        case .pro:
            return String(format: String(localized: "Pro · %lld links"), locale: .current, Int64(limits.live))
        }
    }

    var atCapMessage: String? {
        guard let limits else { return nil }
        if let teamID = target.teamID, let team = limits.team(teamID) {
            return Self.sentences(
                String(format: String(localized: "This team has %lld live links."), locale: .current, Int64(team.live)),
                String(
                    format: String(localized: "Teams allow %lld. Revoke one to share another."),
                    locale: .current,
                    Int64(team.liveLimit)
                )
            )
        }
        let live = String(format: String(localized: "You have %lld live links."), locale: .current, Int64(limits.live))
        let allowance = switch limits.plan {
        case .free: String(localized: "Free allows %lld. Revoke one to share another.")
        case .pro: String(localized: "Pro allows %lld. Revoke one to share another.")
        }
        return Self.sentences(live, String(format: allowance, locale: .current, Int64(limits.liveLimit)))
    }

    var showsProUpsell: Bool {
        target == .personal && limits?.plan == .free
    }

    private static func sentences(_ first: String, _ second: String) -> String {
        first + " " + second
    }

    // A query share always shows its SQL; a result share shows it unless Hide SQL is on.
    var secretWarnings: [String] {
        guard request.kind == .query || !hidesSQL else { return [] }
        return sqlSecretKinds.map { kind in
            String(
                format: String(localized: "This query may contain a secret (%@). Anyone with the link can read it."),
                kind.displayName
            )
        }
    }

    // Only columns sent as they are: a masked or removed one gives nothing away.
    var columnWarning: String? {
        let kept = SecretScanner.scanColumns(columns.filter { $0.action == .keep }.map(\.name))
        guard !kept.isEmpty else { return nil }
        return String(
            format: String(localized: "Some columns may hold secrets: %@."),
            ListFormatter.localizedString(byJoining: kept)
        )
    }

    var columnSummary: String {
        let masked = columns.filter { $0.action == .mask }.count
        let removed = columns.filter { $0.action == .remove }.count
        return String(
            format: String(localized: "%1$lld columns masked, %2$lld removed."),
            locale: .current,
            Int64(masked),
            Int64(removed)
        )
    }

    var hasDetections: Bool {
        columns.contains { $0.detection != nil }
    }

    // Only while Hide SQL is off and there is SQL to hide.
    var hideSQLSuggestion: String? {
        guard request.kind == .result, hasSharedSQL, !hidesSQL, !sqlPersonalData.isEmpty else { return nil }
        return String(
            format: String(localized: "This query contains what looks like personal data (%@). Turn on Hide SQL to keep the query private."),
            ListFormatter.localizedString(byJoining: sqlPersonalData.map(\.displayName))
        )
    }
}

extension ShareSheetModel {
    static func live(_ request: ShareRequest) -> ShareSheetModel {
        ShareSheetModel(
            request: request,
            service: AccountServices.shared.shares,
            isSignedIn: { FeatureAccess.shared.state.isSignedIn },
            signInChanges: FeatureAccess.shared.$state.map(\.isSignedIn).eraseToAnyPublisher(),
            copyToClipboard: { ClipboardService.shared.writeText($0) }
        )
    }
}
