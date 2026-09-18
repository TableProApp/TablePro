//
//  TransportRateLabelTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("TransportRateLabel")
struct TransportRateLabelTests {
    @Test("An idle transport reads zero rather than going blank")
    func idleReadsZero() {
        let text = TransportRateLabel.text(for: .zero)

        #expect(text.contains("0"))
        #expect(text.hasSuffix("kB/s"))
    }

    @Test("No reading yet reads the same as idle")
    func absentRateReadsAsIdle() {
        #expect(TransportRateLabel.text(for: nil) == TransportRateLabel.text(for: .zero))
    }

    /// `.byteCount` spells the smallest unit out in full: measured, `allowedUnits: [.kb]` still
    /// returns "512 bytes" for 512 and "Zero kB" for 0. Both are four characters wider than the
    /// figures around them, which is why the label is assembled rather than formatted.
    @Test("A rate below a kilobyte never spells out bytes")
    func subKilobyteNeverSpellsBytes() {
        let text = TransportRateLabel.text(for: TransportRate(receivedPerSecond: 512, sentPerSecond: 0))

        #expect(!text.lowercased().contains("byte"))
        #expect(text.hasSuffix("kB/s"))
    }

    @Test("Units step up at a thousand")
    func unitsStepUp() {
        let kilo = TransportRateLabel.text(for: TransportRate(receivedPerSecond: 145_408, sentPerSecond: 0))
        let mega = TransportRateLabel.text(for: TransportRate(receivedPerSecond: 4_700_000, sentPerSecond: 0))
        let giga = TransportRateLabel.text(for: TransportRate(receivedPerSecond: 2_400_000_000, sentPerSecond: 0))

        #expect(kilo.hasSuffix("kB/s"))
        #expect(mega.hasSuffix("MB/s"))
        #expect(giga.hasSuffix("GB/s"))
    }

    @Test("The busier direction picks the arrow")
    func arrowFollowsTheBusierDirection() {
        let down = TransportRateLabel.text(for: TransportRate(receivedPerSecond: 145_408, sentPerSecond: 12))
        let up = TransportRateLabel.text(for: TransportRate(receivedPerSecond: 12, sentPerSecond: 145_408))

        #expect(down.hasPrefix("\u{2193}"))
        #expect(up.hasPrefix("\u{2191}"))
    }

    @Test("An arrow is never what VoiceOver is given to read")
    func accessibilityValueNamesTheDirection() {
        let down = TransportRateLabel.accessibilityValue(for: TransportRate(receivedPerSecond: 145_408, sentPerSecond: 0))
        let up = TransportRateLabel.accessibilityValue(for: TransportRate(receivedPerSecond: 0, sentPerSecond: 145_408))

        #expect(!down.contains("\u{2193}"))
        #expect(!up.contains("\u{2191}"))
        #expect(down != up)
    }

    /// The field measures itself against these once, so a format that can produce something wider
    /// than all of them would clip its own text.
    @Test("No rate renders wider than the widest candidate the field is sized from")
    func noRateOutgrowsTheField() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let budget = TransportRateLabel.widestCandidates
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0

        let rates: [Double] = [0, 1, 512, 1_000, 1_500, 9_900, 64_000, 145_408, 512_000, 999_000,
                               1_200_000, 4_700_000, 12_500_000, 88_000_000, 999_000_000, 2_400_000_000]

        for value in rates {
            let text = TransportRateLabel.text(for: TransportRate(receivedPerSecond: value, sentPerSecond: 0))
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= budget, "\(value) B/s rendered \"\(text)\" at \(width)pt, past the \(budget)pt budget")
        }
    }

    /// Monospaced digits are what make the drawn text hold still inside a fixed field: the figure
    /// changes, the glyph advances do not.
    @Test("Every figure of the same shape draws to the same width")
    func figuresOfOneShapeDrawAlike() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let threeDigitKilobytes: [Double] = [111_000, 145_408, 512_000, 999_000]

        let widths = threeDigitKilobytes.map { value -> CGFloat in
            let text = TransportRateLabel.text(for: TransportRate(receivedPerSecond: value, sentPerSecond: 0))
            return (text as NSString).size(withAttributes: [.font: font]).width
        }

        let widest = widths.max() ?? 0
        let narrowest = widths.min() ?? 0
        #expect(widest - narrowest < 0.01, "Monospaced digits must not vary: spread was \(widest - narrowest)pt")
    }
}
