//
//  ShareSheet.swift
//  TablePro
//

import SwiftUI

internal struct ShareSheet: View {
    @StateObject private var model: ShareSheetModel
    @State private var linkToRevoke: ShareLink?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(model: @autoclosure @escaping () -> ShareSheetModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(model.isResult ? String(localized: "Share Result") : String(localized: "Share Query"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityAddTraits(.isHeader)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            DialogFooter {
                if let footer = model.footer {
                    Text(footer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("share-sheet-usage")
                }
            } actions: {
                actions
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: model.isResult ? 640 : 480)
        .interactiveDismissDisabled(model.isCreating)
        // Done and Close carry Return, so Esc closes these two through the window.
        .onExitCommand {
            switch model.phase {
            case .created, .sharingDisabled: dismiss()
            default: break
            }
        }
        .task { await model.load() }
        .onDisappear { model.close() }
        .alert(
            revokeTitle,
            isPresented: Binding(get: { linkToRevoke != nil }, set: { if !$0 { linkToRevoke = nil } }),
            presenting: linkToRevoke
        ) { link in
            Button(String(localized: "Revoke"), role: .destructive) {
                Task { await model.revoke(link) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Anyone with the link can no longer open it. This can't be undone.")
        }
    }

    private var revokeTitle: String {
        let title = linkToRevoke.map(LiveLinkRow.displayTitle) ?? ""
        return String(format: String(localized: "Revoke “%@”?"), title)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .signedOut:
            message(
                String(localized: "Sign in to your TablePro account to share links."),
                systemImage: "person.crop.circle"
            )
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Loading"))
        case .loadFailed(let text):
            UnavailableStateView {
                Label(text, systemImage: "wifi.exclamationmark")
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await model.load() }
                }
            }
        case .emailUnverified:
            message(String(localized: "Verify your email address to share links."), systemImage: "envelope.badge")
        case .sharingDisabled:
            message(String(localized: "Sharing is turned off for this account."), systemImage: "nosign")
        case .atCap:
            atCapContent
        case .form:
            formContent
        case .created(let url):
            createdContent(url)
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        UnavailableStateView {
            Label(text, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        if !model.teams.isEmpty {
            Section {
                Picker(String(localized: "Share as"), selection: $model.target) {
                    Text("Personal").tag(ShareTarget.personal)
                    ForEach(model.teams) { team in
                        TeamChoice(team: team)
                            .tag(ShareTarget.team(team.id))
                            .disabled(!team.allowsPublicLinks)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isCreating)
                .accessibilityIdentifier("share-sheet-target")
            }
        }
    }

    private var formContent: some View {
        Form {
            targetSection

            Section {
                TextField(String(localized: "Title"), text: $model.title)
                    .accessibilityIdentifier("share-sheet-title")
                TextField(String(localized: "Note"), text: $model.note, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("share-sheet-note")
            }

            Section {
                expiryRow
                if model.isResult {
                    Toggle(String(localized: "Hide SQL"), isOn: $model.hidesSQL)
                        .accessibilityIdentifier("share-sheet-hide-sql")
                }
                passwordRow
                if let message = model.passwordTooLongMessage {
                    NoticeLabel(message, severity: .error)
                }
                downloadRow
            }

            if model.isResult {
                previewSection
            }

            if let message = model.sqlTooLongMessage {
                Section {
                    NoticeLabel(message, severity: .error)
                        .accessibilityIdentifier("share-sheet-sql-too-long")
                }
            }

            if !model.secretWarnings.isEmpty || model.columnWarning != nil {
                Section {
                    ForEach(model.secretWarnings, id: \.self) { warning in
                        NoticeLabel(warning)
                    }
                    if let warning = model.columnWarning {
                        NoticeLabel(warning)
                    }
                }
            }

            if let failure = model.failureMessage {
                Section {
                    NoticeLabel(failure, severity: .error)
                        .accessibilityIdentifier("share-sheet-error")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isCreating)
    }

    private var expiryRow: some View {
        LabeledContent {
            Picker(String(localized: "Expires"), selection: $model.expiry) {
                ForEach(ShareExpiry.allCases) { expiry in
                    Text(expiry.displayName)
                        .tag(expiry)
                        .disabled(!model.isAvailable(expiry))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("share-sheet-expiry")
        } label: {
            proLabel(String(localized: "Expires"), showsTag: !model.isAvailable(.never))
        }
    }

    private var passwordRow: some View {
        LabeledContent {
            SecureField(String(localized: "Password"), text: $model.password)
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(!(model.limits?.allowsPassword ?? false))
                .accessibilityIdentifier("share-sheet-password")
        } label: {
            proLabel(String(localized: "Password"), showsTag: !(model.limits?.allowsPassword ?? false))
        }
    }

    private var downloadRow: some View {
        LabeledContent {
            Toggle(String(localized: "Allow viewers to download"), isOn: $model.allowsDownload)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!(model.limits?.allowsDisablingDownload ?? false))
                .accessibilityIdentifier("share-sheet-allow-download")
        } label: {
            proLabel(
                String(localized: "Allow viewers to download"),
                showsTag: !(model.limits?.allowsDisablingDownload ?? false)
            )
        }
    }

    private func proLabel(_ title: String, showsTag: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if showsTag {
                ProTag()
            }
        }
    }

    private var previewSection: some View {
        Section {
            if model.isSnapshotTooLarge {
                NoticeLabel(String(localized: "This result is too large to share."), severity: .error)
            } else {
                SharePreviewGrid(columns: model.previewColumns, rows: model.previewRows)
                if let note = model.capNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("share-sheet-cap-note")
                }
            }
        } header: {
            Text("Rows that will be shared")
        }
    }

    private var atCapContent: some View {
        Form {
            targetSection

            Section {
                if let text = model.atCapMessage {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.showsProUpsell {
                    HStack(spacing: 6) {
                        Text("Pro allows up to 1,000.")
                            .foregroundStyle(.secondary)
                        ProTag()
                    }
                }
            }

            Section {
                if model.isLoadingLinks, model.liveLinks.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("Loading"))
                }
                ForEach(model.liveLinks) { link in
                    LiveLinkRow(
                        link: link,
                        isRevoking: model.revokingLinkIDs.contains(link.id),
                        revoke: { linkToRevoke = link }
                    )
                }
                if let failure = model.linksFailure {
                    HStack {
                        NoticeLabel(failure, severity: .error)
                        Spacer(minLength: 8)
                        Button(String(localized: "Try Again")) {
                            Task { await model.loadLiveLinks() }
                        }
                        .disabled(model.isLoadingLinks)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func createdContent(_ url: URL) -> some View {
        VStack(spacing: 14) {
            Label {
                Text("Link copied")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

            Text(verbatim: url.absoluteString)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("share-sheet-url")

            HStack(spacing: 10) {
                Button(String(localized: "Copy")) { model.copyLink() }
                Button(String(localized: "Open in Browser")) { openURL(url) }
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .signedOut:
            cancelButton
            Button(String(localized: "Sign In…")) { SignInWindowController.present() }
                .keyboardShortcut(.defaultAction)
        case .emailUnverified:
            cancelButton
            Button(String(localized: "Open Account")) {
                openURL(AccountServices.shared.configuration.accountURL)
            }
            .keyboardShortcut(.defaultAction)
        case .form:
            if model.isCreating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Creating the link"))
            }
            // A create already sent finishes on the server whether or not the sheet stays.
            cancelButton
                .disabled(model.isCreating)
            Button(String(localized: "Create Link")) {
                Task { await model.create() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCreate)
            .accessibilityIdentifier("share-sheet-create")
        case .created:
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .sharingDisabled:
            Button(String(localized: "Close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .loading, .loadFailed, .atCap:
            cancelButton
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
    }
}

private struct TeamChoice: View {
    let team: ShareTeam

    var body: some View {
        if team.allowsPublicLinks {
            Text(verbatim: team.name)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: team.name)
                Text("Public links are off for this team.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Opens the plan details in the browser rather than a sheet over a sheet.
private struct ProTag: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(SupportLinks.pricing(.shareSheet))
        } label: {
            Text("Pro")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityHint(Text("Opens the Pro plan details in your browser."))
    }
}

private struct LiveLinkRow: View {
    let link: ShareLink
    let isRevoking: Bool
    let revoke: () -> Void

    static func displayTitle(_ link: ShareLink) -> String {
        link.title.isEmpty ? String(localized: "Untitled") : link.title
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if link.isSuspended {
                    Text("Suspended")
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "Revoke"), action: revoke)
                    .disabled(isRevoking)
                    .accessibilityLabel(Text(String(format: String(localized: "Revoke %@"), Self.displayTitle(link))))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.displayTitle(link))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        let created = link.createdAt.formatted(date: .abbreviated, time: .omitted)
        guard let expires = link.expiresAt else { return created }
        return String(
            format: String(localized: "%1$@ · Expires %2$@"),
            created,
            expires.formatted(date: .abbreviated, time: .omitted)
        )
    }
}

private struct SharePreviewGrid: View {
    let columns: [ShareSnapshot.Column]
    let rows: [[ShareCell]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    ForEach(columns.indices, id: \.self) { index in
                        Text(verbatim: columns[index].name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { index in
                            cell(rows[rowIndex].indices.contains(index) ? rows[rowIndex][index] : .null)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Rows that will be shared"))
        .accessibilityIdentifier("share-sheet-preview")
    }

    @ViewBuilder
    private func cell(_ value: ShareCell) -> some View {
        switch value {
        case .null:
            Text(verbatim: "NULL")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        default:
            Text(verbatim: Self.text(value))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
        }
    }

    private static func text(_ value: ShareCell) -> String {
        let line = ShareCellEncoder.previewText(value).prefix(200)
        return line.replacingOccurrences(of: "\n", with: " ", options: .literal)
    }
}
