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

    // The server's field caps (api/v2.json, CreateShareBody), counted as the server counts them: Unicode scalars, and
    // UTF-8 bytes for the SQL.
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
    // Set when the created link holds only the first columns.
    @Published private(set) var createdColumnCapNote: String?
    @Published private(set) var failureMessage: String?
    @Published private(set) var sqlSecretKinds: [SecretKind] = []
    @Published private(set) var sqlPersonalData: [SensitiveValueKind] = []
    @Published private(set) var columns: [ShareColumnChoice] = []
    // The loader found the result gone, as when its tab closed or shows another result.
    @Published private(set) var isResultGone = false
    // The rows were masked again since the snapshot was built, and are being read again.
    @Published private(set) var isSourceStale = false

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
    private var sourceObservation: AnyCancellable?
    private var appliedDefaults = false
    private var sourceMaxRows: Int?
    private var loadingMaxRows: Int?
    // Moves on every read of the rows, so a read another one overtook is dropped.
    private var sourceGeneration = 0
    private var sourceReload: Task<Void, Never>?
    // The rows the detectors read; a rebuild never sends past them.
    private var rowCap: Int?
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
        sourceObservation = request.sourceChanges?.sink { [weak self] in
            self?.sourceChanged()
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

    // Up to 10,000 rows of 100 columns: read, scanned and built off the main actor, once per row limit unless forced.
    private func loadSource(maxRows: Int, force: Bool = false) async {
        guard let load = request.loadResult, force || sourceMaxRows != maxRows else { return }
        sourceGeneration += 1
        let generation = sourceGeneration
        loadingMaxRows = maxRows
        let loaded = await load(maxRows)
        guard !Task.isCancelled, !isClosed, generation == sourceGeneration else { return }
        guard let loaded else {
            isResultGone = true
            return
        }
        isResultGone = false
        // The old snapshot and choices belong to the rows being replaced: nothing built from them is sent.
        let previous = columns
        rebuild?.cancel()
        source = loaded
        snapshot = nil
        builtColumns = nil
        rowCap = nil
        columns = []
        scanSQL(loaded.sql)
        let prepare = Task.detached(priority: .userInitiated) {
            ShareColumnChoice.prepare(loaded, maxRows: maxRows, keeping: previous)
        }
        let prepared = await withTaskCancellationHandler {
            await prepare.value
        } onCancel: {
            prepare.cancel()
        }
        guard let prepared, !isClosed, generation == sourceGeneration else { return }
        sourceMaxRows = maxRows
        isSourceStale = false
        rowCap = prepared.rowCap
        columns = prepared.columns
        snapshot = prepared.snapshot
        builtColumns = prepared.columns
    }

    // A masking rule saved in another window masked the rows again: Create waits for them to be read once more.
    private func sourceChanged() {
        guard !isClosed, request.kind == .result, let maxRows = sourceMaxRows ?? loadingMaxRows else { return }
        isSourceStale = true
        sourceReload?.cancel()
        let task = Task { await loadSource(maxRows: maxRows, force: true) }
        sourceReload = task
        track(task)
    }

    private func buildSnapshot() async {
        guard let source, let rowCap else { return }
        let generation = sourceGeneration
        let choices = columns
        let shared = choices.compactMap(\.sharedColumn)
        let build = Task.detached(priority: .userInitiated) {
            ShareSnapshotBuilder.build(source, maxRows: rowCap, columns: shared)
        }
        let built = await withTaskCancellationHandler {
            await build.value
        } onCancel: {
            build.cancel()
        }
        guard let built, !Task.isCancelled, !isClosed, choices == columns, generation == sourceGeneration else { return }
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

    // Also while a change to the columns or the rules is rebuilding the snapshot, so Create never sends values masked
    // the old way.
    var isPreparingRows: Bool {
        request.kind == .result && (snapshot == nil || builtColumns != columns || isSourceStale)
    }

    var resultGoneMessage: String? {
        guard request.kind == .result, isResultGone else { return nil }
        return String(localized: "This result is no longer open, so there are no rows to share.")
    }

    var sharedSQL: String {
        source?.sql ?? request.sql
    }

    // A table view the host cannot write as SQL shares its rows alone.
    var hasSharedSQL: Bool {
        !sharedSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sqlTooLongMessage: String? {
        guard sharedSQL.utf8.count > Self.sqlLimit else { return nil }
        return String(
            format: String(localized: "This query is too long to share. A link holds up to %@ of SQL."),
            ByteCountFormatter.string(fromByteCount: Int64(Self.sqlLimit), countStyle: .memory)
        )
    }

    // Readers send the password in a header, where HTTP drops leading and trailing spaces and tabs.
    static func sentPassword(_ typed: String) -> String {
        typed.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    // A password the plan no longer allows, as after a reload as Free, is never dropped silently.
    var passwordMessage: String? {
        guard !password.isEmpty else { return nil }
        if let limits, !limits.allowsPassword {
            return Self.sentences(Self.proRequired, String(localized: "Clear the password to create the link."))
        }
        let sent = Self.sentPassword(password)
        if sent.isEmpty {
            return String(localized: "A password can't be only spaces or tabs.")
        }
        guard sent.unicodeScalars.count > Self.passwordLimit else { return nil }
        return String(
            format: String(localized: "A password can be up to %lld characters."),
            locale: .current,
            Int64(Self.passwordLimit)
        )
    }

    var expiryMessage: String? {
        guard let limits, !limits.allows(expiry) else { return nil }
        return Self.sentences(Self.proRequired, String(localized: "Choose another expiry to create the link."))
    }

    var downloadMessage: String? {
        guard !allowsDownload, let limits, !limits.allowsDisablingDownload else { return nil }
        return Self.sentences(Self.proRequired, String(localized: "Turn downloads back on to create the link."))
    }

    private static var proRequired: String {
        String(localized: "This option needs TablePro Pro.")
    }

    var canCreate: Bool {
        phase == .form && !isCreating && !isSnapshotTooLarge && !isEveryColumnRemoved && !isPreparingRows
            && !isResultGone && sqlTooLongMessage == nil && passwordMessage == nil && expiryMessage == nil
            && downloadMessage == nil
    }

    func create() async {
        guard canCreate, let draft = makeDraft() else { return }
        isCreating = true
        failureMessage = nil
        defer { isCreating = false }
        let capNote = isColumnCapped
            ? String(
                format: String(localized: "The link shares the first %lld columns."),
                locale: .current,
                Int64(ShareSnapshotBuilder.maxColumns)
            )
            : nil
        do throws(ShareFailure) {
            let created = try await service.create(draft)
            guard !isClosed else { return }
            copyToClipboard(created.url.absoluteString)
            adjustLive(by: 1)
            createdColumnCapNote = capNote
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
        guard limits != nil, !isSourceStale, !isResultGone, passwordMessage == nil, expiryMessage == nil,
              downloadMessage == nil
        else { return nil }
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
        let sentPassword = Self.sentPassword(password)
        return ShareDraft(
            kind: request.kind,
            sql: sharedSQL,
            title: Self.clipped(title.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.titleLimit),
            note: trimmedNote.isEmpty ? nil : Self.clipped(trimmedNote, to: Self.noteLimit),
            dialect: request.dialect,
            expiry: expiry,
            hidesSQL: request.kind == .result && hasSharedSQL ? hidesSQL : nil,
            allowsDownload: allowsDownload ? nil : false,
            password: sentPassword.isEmpty ? nil : sentPassword,
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

    // The first kept columns up to the server's cap; the rest are not sent.
    private var sentColumns: ArraySlice<ShareColumnChoice> {
        columns.filter { $0.action != .remove }.prefix(ShareSnapshotBuilder.maxColumns)
    }

    var isColumnCapped: Bool {
        columns.filter { $0.action != .remove }.count > ShareSnapshotBuilder.maxColumns
    }

    var columnCapNote: String? {
        guard isColumnCapped else { return nil }
        return String(
            format: String(localized: "Shares the first %lld columns."),
            locale: .current,
            Int64(ShareSnapshotBuilder.maxColumns)
        )
    }

    var columnSummary: String {
        let masked = sentColumns.filter { $0.action == .mask }.count
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
