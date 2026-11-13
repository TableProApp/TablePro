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

    // The server's field caps (api.md, POST /v2/shares).
    static let titleLimit = 200
    static let noteLimit = 2_000
    static let passwordLimit = 128
    static let previewRowCount = 5

    let request: ShareRequest

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var limits: ShareLimits?
    @Published private(set) var snapshot: ShareSnapshotOutcome?
    @Published private(set) var liveLinks: [ShareLink] = []
    @Published private(set) var isLoadingLinks = false
    @Published private(set) var linksFailure: String?
    @Published private(set) var revokingLinkIDs: Set<String> = []
    @Published private(set) var isCreating = false
    @Published private(set) var failureMessage: String?

    @Published var title: String
    @Published var note = ""
    @Published var expiry: ShareExpiry = .thirtyDays
    @Published var hidesSQL = false
    @Published var password = ""
    @Published var allowsDownload = true

    private let service: any ShareService
    private let sqlSecretKinds: [SecretKind]
    private let sensitiveColumns: [String]
    private let isSignedIn: @MainActor () -> Bool
    private let copyToClipboard: @MainActor (String) -> Void
    private var signInObservation: AnyCancellable?
    private var appliedDefaults = false
    private var snapshotMaxRows: Int?

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
        self.title = String(request.title.prefix(Self.titleLimit))
        var kinds: [SecretKind] = []
        for hit in SecretScanner.scanSQL(request.sql) where !kinds.contains(hit.kind) {
            kinds.append(hit.kind)
        }
        self.sqlSecretKinds = kinds
        self.sensitiveColumns = SecretScanner.scanColumns(request.result?.columns ?? [])
        signInObservation = signInChanges
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, self.phase == .signedOut else { return }
                Task { await self.load() }
            }
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
            await buildSnapshot(maxRows: limits.maxRows)
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
        if !limits.emailVerified {
            phase = .emailUnverified
        } else if limits.sharingDisabled {
            phase = .sharingDisabled
        } else if limits.isAtCap {
            phase = .atCap
            Task { await loadLiveLinks() }
        } else {
            phase = .form
        }
    }

    // Up to 10,000 rows of 100 columns: built off the main actor, once per row limit.
    private func buildSnapshot(maxRows: Int) async {
        guard let source = request.result, snapshotMaxRows != maxRows else { return }
        snapshot = await Task.detached(priority: .userInitiated) {
            ShareSnapshotBuilder.build(source, maxRows: maxRows)
        }.value
        snapshotMaxRows = maxRows
    }

    func loadLiveLinks() async {
        guard !isLoadingLinks else { return }
        isLoadingLinks = true
        defer { isLoadingLinks = false }
        do throws(ShareFailure) {
            liveLinks = try await service.liveLinks().sorted { $0.createdAt < $1.createdAt }
            linksFailure = nil
        } catch .canceled {
            return
        } catch {
            linksFailure = Self.loadMessage(error)
        }
    }

    // MARK: - At the cap

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
        liveLinks.removeAll { $0.id == link.id }
        guard let limits else { return }
        let freed = limits.withLive(max(0, limits.live - 1))
        self.limits = freed
        if !freed.isAtCap, phase == .atCap {
            phase = .form
        }
    }

    // MARK: - Creating

    var isSnapshotTooLarge: Bool {
        snapshot == .tooLarge
    }

    var canCreate: Bool {
        phase == .form && !isCreating && !isSnapshotTooLarge
            && password.count <= Self.passwordLimit
    }

    func create() async {
        guard canCreate, let draft = makeDraft() else { return }
        isCreating = true
        failureMessage = nil
        defer { isCreating = false }
        do throws(ShareFailure) {
            let created = try await service.create(draft)
            copyToClipboard(created.url.absoluteString)
            if let limits {
                self.limits = limits.withLive(limits.live + 1)
            }
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
        case (.result, .snapshot(let built)):
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
            sql: request.sql,
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.titleLimit)),
            note: trimmedNote.isEmpty ? nil : String(trimmedNote.prefix(Self.noteLimit)),
            dialect: request.dialect,
            expiry: limits.allows(expiry) ? expiry : limits.defaultExpiry,
            hidesSQL: request.kind == .result ? hidesSQL : nil,
            allowsDownload: limits.allowsDisablingDownload && !allowsDownload ? false : nil,
            password: usesPassword ? String(password.prefix(Self.passwordLimit)) : nil,
            snapshot: snapshotValue
        )
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
        return String(
            format: String(localized: "Shares the first %1$@ of %2$@ rows."),
            built.rows.count.formatted(),
            built.rowCount.formatted()
        )
    }

    var footer: String? {
        guard let limits else { return nil }
        switch limits.plan {
        case .free:
            return String(
                format: String(localized: "Free · %1$@ of %2$@ links · first %3$@ rows"),
                limits.live.formatted(),
                limits.liveLimit.formatted(),
                limits.maxRows.formatted()
            )
        case .pro:
            let format = limits.live == 1 ? String(localized: "Pro · %@ link") : String(localized: "Pro · %@ links")
            return String(format: format, limits.live.formatted())
        }
    }

    var atCapMessage: String? {
        guard let limits else { return nil }
        switch limits.plan {
        case .free:
            return String(
                format: String(localized: "You have %@ live links, the Free limit. Revoke one to share another."),
                limits.liveLimit.formatted()
            )
        case .pro:
            return String(
                format: String(localized: "You have %@ live links. Revoke one to share another."),
                limits.liveLimit.formatted()
            )
        }
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

    var columnWarning: String? {
        guard !sensitiveColumns.isEmpty else { return nil }
        return String(
            format: String(localized: "Some columns may hold secrets: %@."),
            ListFormatter.localizedString(byJoining: sensitiveColumns)
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
