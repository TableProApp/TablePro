import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import TableProFFI
import UIKit

// Confirming a member is an owner's or admin's action (core ADR 0056, Teams): the words of the key this device pinned
// for them, compared out of band, then a wrap of the current team key version to that key.
struct TeamMemberConfirmSheet: View {
    let model: TeamKeysModel
    let member: TeamMemberKeys

    @Environment(\.dismiss) private var dismiss
    @State private var words: TeamFingerprintLoad = .loading
    @State private var showsMismatch = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(
                        format: String(localized: "Ask %1$@ to read the six words under Show My Words for %2$@. Confirm only if they match these."),
                        member.displayName,
                        model.team.name
                    ))
                    .foregroundStyle(.secondary)
                }
                Section {
                    TeamFingerprintLoadView(load: words)
                }
                Section {
                    Button(String(localized: "Words Don't Match"), role: .destructive) { showsMismatch = true }
                        .disabled(!hasWords)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(format: String(localized: "Confirm %@"), member.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Confirm")) {
                        Task {
                            if await model.confirm(member) { dismiss() }
                        }
                    }
                    .disabled(!hasWords || model.work != nil)
                }
            }
        }
        .task { await loadWords() }
        .alert(String(format: String(localized: "Don't Confirm %@"), member.displayName), isPresented: $showsMismatch) {
            Button(String(localized: "Close")) { dismiss() }
        } message: {
            Text("The keys this device has for them aren't the keys they hold, so someone may be standing in for them. Tell the person who runs your TablePro server.")
        }
    }

    private var hasWords: Bool {
        if case .loaded = words { return true }
        return false
    }

    private func loadWords() async {
        guard !hasWords else { return }
        do {
            words = .loaded(try await model.service.accountFingerprint(account: member.account))
        } catch {
            words = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load their words."))
        }
    }
}

// A key-change alert (core ADR 0056, Pins, Any other change): until the person compares or accepts, this device wraps
// nothing to the account. Accepting without comparing is allowed and recorded as a first use.
struct TeamKeyChangeSheet: View {
    let model: TeamKeysModel
    let member: TeamMemberKeys

    private enum Load: Equatable {
        case loading
        case loaded(KeyChangeInfo)
        case settled
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var change: Load = .loading

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(format: String(localized: "%@'s Keys Changed"), member.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .loaded(let info) = change {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Words Match")) { accept(info, compared: true) }
                            .disabled(model.work != nil)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close")) { dismiss() }
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch change {
        case .loading:
            TeamFingerprintLoadView(load: .loading)
        case .settled:
            Text("This key change was already settled on this device.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            TeamKeyNoticeLabel(text: message, severity: .error)
        case .loaded(let info):
            Section {
                Text(String(
                    format: String(localized: "The keys TablePro has for %@ changed. That happens when they reset their keys, and also when someone stands in for them. Ask them to read their six words and compare them with the new words."),
                    member.displayName
                ))
                .foregroundStyle(.secondary)
            }
            Section(String(localized: "New Words")) {
                TeamFingerprintWords(words: info.offered.words)
            }
            Section {
                TeamFingerprintWords(words: info.pinned.words, prominence: .secondary)
            } header: {
                Text("Previous Words")
            } footer: {
                if model.canWrapCurrentVersion {
                    Text("Accepting also shares the team key with their new keys.")
                }
            }
            Section {
                Button(String(localized: "Accept Without Comparing")) { accept(info, compared: false) }
                    .disabled(model.work != nil)
            }
        }
    }

    private func load() async {
        guard change == .loading else { return }
        do {
            if let info = try await model.service.accountKeyChange(account: member.account) {
                change = .loaded(info)
            } else {
                change = .settled
            }
        } catch {
            change = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load the key change."))
        }
    }

    private func accept(_ info: KeyChangeInfo, compared: Bool) {
        Task {
            if await model.acceptKeyChange(member, offeredIk: info.offeredIk, compared: compared) {
                dismiss()
            }
        }
    }
}

// No holder left (core ADR 0056, Teams): an owner starts the key over and wraps it to the members it confirms, each
// after a comparison of their words, so nothing is wrapped to someone no person looked at.
struct TeamRestartSheet: View {
    let model: TeamKeysModel
    @State private var selection: TeamRestartSelection
    @State private var shownWords: String?

    @Environment(\.dismiss) private var dismiss

    init(model: TeamKeysModel) {
        self.model = model
        _selection = State(wrappedValue: TeamRestartSelection(service: model.service))
    }

    private var candidates: [TeamMemberKeys] {
        model.snapshot.map(TeamKeysPresentation.restartCandidates) ?? []
    }

    private var waitingForKeyChange: [TeamMemberKeys] {
        model.snapshot.map(TeamKeysPresentation.restartWaitsForKeyChange) ?? []
    }

    private var changedNames: [String] {
        selection.changed.compactMap { account in candidates.first { $0.account == account }?.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(
                        format: String(localized: "No one on %@ holds the current team key, so it can't be passed on. Starting over makes a new key and shares it with the members you include. Passwords saved under the old key stay readable only where a device still has that key."),
                        model.team.name
                    ))
                    .foregroundStyle(.secondary)
                }
                Section {
                    if candidates.isEmpty {
                        Text("No other member has set up their keys yet. You can start over now and confirm them later.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { member in
                        row(member)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !candidates.isEmpty {
                            Text("Compare each member's words with them. Only those whose words match get the new key.")
                        }
                        if !waitingForKeyChange.isEmpty {
                            Text(String(
                                format: String(localized: "Left out until you compare their new keys on the team's keys page: %@."),
                                waitingForKeyChange.map(\.displayName).formatted(.list(type: .and))
                            ))
                        }
                    }
                }
                if !changedNames.isEmpty {
                    Section {
                        TeamKeyNoticeLabel(
                            text: String(
                                format: String(localized: "The keys this device has for %@ changed since you compared them. Compare their words again."),
                                changedNames.formatted(.list(type: .and))
                            ),
                            severity: .warning
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Start the Team Key Over"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Start Over")) {
                        Task { await startOver() }
                    }
                    .disabled(model.work != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ member: TeamMemberKeys) -> some View {
        let included = selection.isIncluded(member.account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: member.displayName)
                    Text(included ? String(localized: "Gets the new key") : TeamKeysPresentation.roleName(member.role))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if included {
                    Button(String(localized: "Leave Out")) { selection.exclude(member.account) }
                        .accessibilityLabel(Text(String(format: String(localized: "Leave out %@"), member.displayName)))
                } else {
                    Button(shownWords == member.account ? String(localized: "Hide Words") : String(localized: "Compare Words")) {
                        shownWords = shownWords == member.account ? nil : member.account
                    }
                    .accessibilityLabel(Text(String(format: String(localized: "Compare %@'s words"), member.displayName)))
                }
            }
            .buttonStyle(.borderless)
            if shownWords == member.account, !included {
                VStack(alignment: .leading, spacing: 8) {
                    TeamFingerprintLoadView(load: selection.words[member.account] ?? .loading)
                    if case .loaded? = selection.words[member.account] {
                        Button(String(localized: "Words Match")) {
                            selection.wordsMatch(member.account)
                            shownWords = nil
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(String(format: String(localized: "%@'s words match"), member.displayName)))
                    }
                }
                .task { await selection.loadWords(member.account) }
            }
        }
    }

    private func startOver() async {
        guard let accounts = await selection.accountsToWrap(in: candidates.map(\.account)) else { return }
        if await model.restart(confirming: accounts) {
            dismiss()
        }
    }
}

// A team restart this device holds (core ADR 0064): it takes the new key only once the person compares the restarting
// owner's six words and accepts. Accepting without comparing is not offered.
struct TeamRestartHeldSheet: View {
    let model: TeamKeysModel

    private enum Load: Equatable {
        case loading
        case loaded(HeldRestartInfo)
        case settled
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var held: Load = .loading

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "The Team Key Was Started Over"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .loaded(let info) = held {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Not Now")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Words Match")) {
                            Task {
                                if await model.acceptRestart(signerIk: info.signerIk) { dismiss() }
                            }
                        }
                        .disabled(model.work != nil)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close")) { dismiss() }
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch held {
        case .loading:
            TeamFingerprintLoadView(load: .loading)
        case .settled:
            Text("This device no longer holds a restarted team key.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            TeamKeyNoticeLabel(text: message, severity: .error)
        case .loaded(let info):
            let signer = model.snapshot?.member(info.signer)
            Section {
                if signer == nil {
                    TeamKeyNoticeLabel(text: TeamKeysPresentation.restartHeldText(signer: nil), severity: .warning)
                } else {
                    Text(TeamKeysPresentation.restartHeldText(signer: signer))
                }
                Text(String(
                    format: String(localized: "Ask %1$@ to read their six words. Until the words match and you accept, this device keeps the passwords it already has for %2$@ and saves no new ones there."),
                    signer?.displayName ?? String(localized: "the owner"),
                    model.team.name
                ))
                .foregroundStyle(.secondary)
            }
            Section {
                TeamFingerprintWords(words: info.words.words)
            }
        }
    }

    private func load() async {
        guard held == .loading else { return }
        do {
            if let info = try await model.service.heldTeamRestart(team: model.team.id) {
                held = .loaded(info)
            } else {
                held = .settled
            }
        } catch {
            held = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load the restart."))
        }
    }
}

// This account's own fingerprint (core ADR 0056, Pins), for the owner or admin who confirms it: six words to read out,
// and the `TPF1:` code a device in the same room can read.
struct TeamOwnWordsSheet: View {
    let model: TeamKeysModel

    @Environment(\.dismiss) private var dismiss
    @State private var load: TeamFingerprintLoad = .loading

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Read these words to the owner or admin who confirms you, or let them take a photo of the code. They are the same on every device of your account.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TeamFingerprintLoadView(load: load)
                }
                if case .loaded(let fingerprint) = load {
                    Section {
                        TeamFingerprintQRCode(text: fingerprint.qr)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Your Words"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .task { await loadWords() }
    }

    private func loadWords() async {
        if case .loaded = load { return }
        do {
            load = .loaded(try await model.service.ownFingerprint())
        } catch {
            load = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load your words."))
        }
    }
}

// An account's six fingerprint words, numbered, in reading order: the person compares them aloud or in a message.
struct TeamFingerprintWords: View {
    let words: [String]
    var prominence: Prominence = .primary

    enum Prominence {
        case primary
        case secondary
    }

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(index + 1)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(verbatim: word)
                        .font(prominence == .primary ? .title3.weight(.medium) : .body)
                        .foregroundStyle(prominence == .primary ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(format: String(localized: "Word %1$lld, %2$@"), Int64(index + 1), word)))
            }
        }
        .padding(.vertical, 4)
    }
}

struct TeamFingerprintLoadView: View {
    let load: TeamFingerprintLoad

    var body: some View {
        switch load {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading words")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .loaded(let fingerprint):
            TeamFingerprintWords(words: fingerprint.words)
        case .failed(let message):
            TeamKeyNoticeLabel(text: message, severity: .error)
        }
    }
}

// The QR code of this account's fingerprint, dark on light in either appearance so a camera reads it.
struct TeamFingerprintQRCode: View {
    let text: String
    var side: CGFloat = 200

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel(Text("QR code of your words"))
        }
    }

    // Whole pixels per module, so the code stays sharp, inside the four-module light margin ISO/IEC 18004 asks for.
    static func image(for text: String, pixelsPerModule: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let margin = 4 * pixelsPerModule
        let scaled = code
            .transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
        let canvas = CGRect(x: 0, y: 0, width: scaled.extent.maxX + margin, height: scaled.extent.maxY + margin)
        let framed = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
        guard let cgImage = CIContext().createCGImage(framed, from: canvas.integral) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
