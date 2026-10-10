import AppKit
import SwiftUI
import TableProImport

internal enum ImportReviewBanner: Equatable {
    case credentialsNotRead
    case notice(String)
}

internal struct ImportReviewStep: View {
    let title: String
    let banner: ImportReviewBanner?
    let onBack: (() -> Void)?
    let onFinished: (ImportOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var review: ImportReview
    @State private var isRequestingImport = false

    init(
        title: String,
        banner: ImportReviewBanner?,
        preview: ImportPreview,
        onBack: (() -> Void)?,
        onFinished: @escaping (ImportOutcome) -> Void
    ) {
        self.title = title
        self.banner = banner
        self.onBack = onBack
        self.onFinished = onFinished
        _review = StateObject(wrappedValue: ImportReview(preview: preview))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(Self.banners(banner, for: review.preview).enumerated()), id: \.offset) { _, banner in
                bannerView(banner)
            }
            Divider()
            ImportPreviewList(review: review)
            Divider()
            footer
        }
        .task(id: isRequestingImport) {
            guard isRequestingImport else { return }
            await runImport()
            isRequestingImport = false
        }
    }

    private var header: some View {
        HStack {
            Text(verbatim: title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func bannerView(_ banner: ImportReviewBanner) -> some View {
        switch banner {
        case .credentialsNotRead:
            bannerLabel(
                String(localized: "Some passwords were not read. You can enter them in the connection editor after import."),
                symbol: "key.slash"
            )
        case .notice(let text):
            bannerLabel(text, symbol: "info.circle")
        }
    }

    private func bannerLabel(_ text: String, symbol: String) -> some View {
        Label {
            Text(verbatim: text)
                .font(.caption)
                .lineLimit(3)
                .help(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(String(localized: "Back")) { onBack() }
                    .disabled(isRequestingImport)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(
                    format: String(localized: "%d of %d connections selected"),
                    review.selectedConnectionCount,
                    review.preview.connections.count
                ))
                if !review.preview.queries.isEmpty {
                    Text(verbatim: String(
                        format: String(localized: "%d of %d saved queries selected"),
                        review.includedQueryCount,
                        review.preview.queries.count
                    ))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()

            if review.isImporting {
                ProgressView()
                    .controlSize(.small)
            }

            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRequestingImport)

            Button(String(localized: "Import")) { isRequestingImport = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(review.plan.isEmpty || isRequestingImport)
                .accessibilityIdentifier("import-review-import")
        }
        .padding(12)
    }

    private func runImport() async {
        let commanded = review.rowsWithCommands
        var keepsCommands = false
        if !commanded.isEmpty {
            let choice = await AlertHelper.confirmThreeWay(
                title: String(localized: "Import Commands?"),
                message: Self.commandConfirmation(for: commanded),
                first: String(localized: "Import Without Commands"),
                second: String(localized: "Import Commands"),
                third: String(localized: "Cancel"),
                window: NSApp.keyWindow
            )
            switch choice {
            case 0:
                keepsCommands = false
            case 1:
                keepsCommands = true
            default:
                return
            }
        }
        let outcome = await review.commit(keepingCommands: keepsCommands)
        onFinished(outcome)
    }

    static func banners(_ banner: ImportReviewBanner?, for preview: ImportPreview) -> [ImportReviewBanner] {
        var banners: [ImportReviewBanner] = []
        if let banner {
            banners.append(banner)
        }
        let rules = preview.environment.rules
        let collected = preview.collected
        if !rules.supportsSavedQueries,
           !collected.bundle.savedQueries.isEmpty || !collected.oversizedQueries.isEmpty {
            banners.append(.notice(String(localized: "Saved queries can't be read right now, so they are not imported.")))
        }
        if !rules.supportsCredentialProfiles, !collected.bundle.credentialProfiles.isEmpty {
            banners.append(.notice(String(
                localized: "Credential profiles can't be read right now, so connections keep their own credentials."
            )))
        }
        return banners
    }

    /// Shows each command in full: it runs on this Mac every time the connection opens, so the
    /// answer has to be given against the text, not against the fact that one exists.
    static func commandConfirmation(for rows: [ConnectionRow]) -> String {
        let entries = rows.map { row -> String in
            let settings = row.settings
            var lines = [settings.name]
            if let tunnel = settings.tunnelCommand
                .map({ TunnelCommandConfiguration($0) })
                .flatMap({
                    TunnelCommandBuilder.previewCommand(
                        for: $0,
                        remoteHost: settings.host.isEmpty ? "localhost" : settings.host,
                        remotePort: settings.port
                    )
                }) {
                lines.append(tunnel)
            }
            if row.carriesStartupCommands, let startup = settings.startupCommands {
                lines.append(String(format: String(localized: "Startup SQL: %@"), Self.excerpt(startup)))
            }
            return lines.joined(separator: "\n")
        }
        return String(
            format: String(localized: """
                These connections run commands every time they connect: a tunnel command on this Mac, \
                SQL on the server, or both.

                %@
                """),
            entries.joined(separator: "\n\n")
        )
    }

    private static func excerpt(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let limit = 300
        return trimmed.length > limit ? trimmed.substring(to: limit) + "…" : trimmed as String
    }
}

internal extension View {
    func importSheetFrame() -> some View {
        frame(minWidth: 560, idealWidth: 620, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity)
    }
}
