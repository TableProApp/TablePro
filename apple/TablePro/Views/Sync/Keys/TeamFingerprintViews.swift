//
//  TeamFingerprintViews.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProFFI

// An account's six fingerprint words, numbered, in reading order: the person compares them aloud or in a message.
internal struct TeamFingerprintWords: View {
    let words: [String]
    var prominence: Prominence = .primary

    enum Prominence {
        case primary
        case secondary
    }

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
                           GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(index + 1)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 12, alignment: .trailing)
                    Text(verbatim: word)
                        .font(prominence == .primary ? .title3.weight(.medium) : .body)
                        .foregroundStyle(prominence == .primary ? .primary : .secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(format: String(localized: "Word %1$lld, %2$@"), index + 1, word)))
            }
        }
    }
}

// The QR code of this account's fingerprint, dark on light in either appearance so a camera reads it.
internal struct TeamFingerprintQRCode: View {
    let text: String
    var side: CGFloat = 168

    var body: some View {
        if let image = TeamFingerprintCode.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel(Text("QR code of your words"))
        }
    }
}

// The words a sheet loads, with the states a load can be in.
internal enum TeamFingerprintLoad: Equatable {
    case loading
    case loaded(FingerprintInfo)
    case failed(String)
}

internal struct TeamFingerprintLoadView: View {
    let load: TeamFingerprintLoad

    var body: some View {
        switch load {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Loading words")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .loaded(let fingerprint):
            TeamFingerprintWords(words: fingerprint.words)
        case .failed(let message):
            NoticeLabel(message, severity: .error)
        }
    }
}
