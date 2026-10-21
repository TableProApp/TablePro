//
//  ValueLengthReadout.swift
//  TablePro
//

import SwiftUI

// Characters are code points, the unit LENGTH and CHAR_LENGTH count, so a value holding an invisible
// character reads one longer than it looks. Bytes are its UTF-8 length.
internal struct ValueLengthSummary: Equatable {
    let characterCount: Int
    let byteCount: Int
    let holdsBidiControl: Bool

    init(_ value: String) {
        var characters = 0
        var holdsBidiControl = false
        for scalar in value.unicodeScalars {
            characters += 1
            if scalar.properties.isBidiControl { holdsBidiControl = true }
        }
        characterCount = characters
        byteCount = value.utf8.count
        self.holdsBidiControl = holdsBidiControl
    }

    var lengthText: String {
        String(format: String(localized: "%1$@, %2$@"), Self.characters(characterCount), Self.bytes(byteCount))
    }

    private static func characters(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 character")
            : String(format: String(localized: "%@ characters"), count.formatted())
    }

    private static func bytes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 byte") : String(format: String(localized: "%@ bytes"), count.formatted())
    }
}

internal struct ValueLengthReadout: View {
    let value: String

    var body: some View {
        let summary = ValueLengthSummary(value)
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if summary.holdsBidiControl {
                Label(Self.bidiWarning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Self.bidiWarning)
            }
            Spacer(minLength: 0)
            Text(summary.lengthText)
                .monospacedDigit()
                .help(String(localized: "Characters are Unicode code points. Bytes are the length in UTF-8."))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .statusBarChrome()
    }

    private static var bidiWarning: String {
        String(localized: "Holds a bidirectional control, which can change the order the text is shown in")
    }
}
