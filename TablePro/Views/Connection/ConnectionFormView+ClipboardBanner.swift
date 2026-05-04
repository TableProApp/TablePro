import AppKit
import SwiftUI
import TableProPluginKit

internal struct ClipboardConnectionBanner: View {
    let summary: String
    let onUse: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(String(localized: "Use clipboard URL"))
                .font(.callout)
                .foregroundStyle(.primary)

            Text(summary)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)

            Spacer(minLength: 8)

            Button(action: onUse) {
                Text(String(localized: "Use"))
            }
            .buttonStyle(.link)
            .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4))
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.separator)
        }
    }
}

extension ConnectionFormView {
    @ViewBuilder
    var clipboardConnectionBannerView: some View {
        if let parsed = clipboardCandidate {
            ClipboardConnectionBanner(
                summary: ConnectionFormView.summary(for: parsed),
                onUse: { applyClipboardCandidate(parsed) },
                onDismiss: dismissClipboardCandidate
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    func detectClipboardConnectionStringIfNeeded(
        connectionStorage: ConnectionStorage = .shared,
        pasteboard: NSPasteboard = .general
    ) {
        guard isNew, !clipboardBannerDismissed, clipboardCandidate == nil else { return }
        guard let raw = pasteboard.string(forType: .string) else { return }
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return }

        let parsed: ParsedConnection
        do {
            parsed = try ConnectionStringParser.parse(firstLine)
        } catch {
            return
        }

        if matchesExistingConnection(parsed: parsed, connectionStorage: connectionStorage) {
            return
        }

        clipboardCandidate = parsed
    }

    func applyClipboardCandidate(_ parsed: ParsedConnection) {
        type = parsed.type
        host = parsed.host
        if parsed.port > 0 {
            port = String(parsed.port)
        } else {
            port = String(parsed.type.defaultPort)
        }
        username = parsed.username ?? ""
        password = parsed.password ?? ""
        database = parsed.database ?? ""
        promptForPassword = false

        if name.isEmpty {
            let suggestion = parsed.database.map { "\(parsed.type.rawValue) \(parsed.host)/\($0)" }
                ?? "\(parsed.type.rawValue) \(parsed.host)"
            name = suggestion
        }

        if parsed.useSSL {
            switch sslMode {
            case .disabled:
                sslMode = .required
            default:
                break
            }
        }

        if parsed.type == .mongodb {
            if let authSource = parsed.queryParameters["authSource"], !authSource.isEmpty {
                additionalFieldValues["mongoAuthSource"] = authSource
            }
            if parsed.rawScheme == "mongodb+srv" {
                additionalFieldValues["mongoUseSrv"] = "true"
            }
        }

        clipboardCandidate = nil
    }

    func dismissClipboardCandidate() {
        clipboardCandidate = nil
        clipboardBannerDismissed = true
    }

    private func matchesExistingConnection(
        parsed: ParsedConnection,
        connectionStorage: ConnectionStorage
    ) -> Bool {
        connectionStorage.loadConnections().contains { saved in
            saved.host == parsed.host
                && saved.port == parsed.port
                && saved.username == (parsed.username ?? "")
        }
    }

    static func summary(for parsed: ParsedConnection) -> String {
        var rendered = parsed.rawScheme + "://"
        if let user = parsed.username, !user.isEmpty {
            rendered += user
            if parsed.password != nil {
                rendered += ":***"
            }
            rendered += "@"
        }
        rendered += parsed.host
        if parsed.port > 0 {
            rendered += ":\(parsed.port)"
        }
        if let database = parsed.database {
            rendered += "/\(database)"
        }
        if rendered.count > 60 {
            let prefix = rendered.prefix(48)
            let suffix = rendered.suffix(8)
            rendered = "\(prefix)...\(suffix)"
        }
        return rendered
    }
}
