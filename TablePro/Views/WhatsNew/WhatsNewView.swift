//
//  WhatsNewView.swift
//  TablePro
//

import SwiftUI

/// What the running version brought, rendered from the bundled `WhatsNew.md`.
///
/// Markdown through `AttributedString(markdown:)` rather than a web view, per the native-only
/// rule. The file is generated from the same CHANGELOG lead block the Sparkle feed carries, so
/// the window and the update dialog cannot disagree about what a release contained.
struct WhatsNewView: View {
    private let content: WhatsNewContent
    private let onViewFullChangelog: () -> Void

    init(content: WhatsNewContent = .bundled, onViewFullChangelog: @escaping () -> Void) {
        self.content = content
        self.onViewFullChangelog = onViewFullChangelog
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(content.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Button(String(localized: "View Full Changelog"), action: onViewFullChangelog)
                    .accessibilityIdentifier("whats-new-full-changelog")
                Spacer()
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.title3.weight(.semibold))
                Text(String(format: String(localized: "Version %@"), Bundle.main.appVersion))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }
}

/// The bundled notes, parsed once.
///
/// A missing or unreadable file is not a failure worth showing: the window still opens, says so
/// plainly and offers the changelog button, which is the route that always works.
struct WhatsNewContent {
    let title: String
    let paragraphs: [AttributedString]

    static var bundled: WhatsNewContent {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return WhatsNewContent(
                title: String(localized: "What's New"),
                paragraphs: [AttributedString(String(localized: "Release notes are on the changelog."))]
            )
        }
        return parse(markdown)
    }

    static func parse(_ markdown: String) -> WhatsNewContent {
        var title = String(localized: "What's New")
        var body: [AttributedString] = []

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text.hasPrefix("# ") {
                title = String(text.dropFirst(2))
                continue
            }
            // Inline markdown only. A full document parse would collapse the lines into one
            // block, and each line here is its own point.
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                body.append(attributed)
            } else {
                body.append(AttributedString(text))
            }
        }

        if body.isEmpty {
            body = [AttributedString(String(localized: "Release notes are on the changelog."))]
        }
        return WhatsNewContent(title: title, paragraphs: body)
    }
}
