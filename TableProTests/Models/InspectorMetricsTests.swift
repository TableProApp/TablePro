//
//  InspectorMetricsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Inspector metrics")
struct InspectorMetricsTests {
    /// Every surface in the pane sits on one edge. It did not: the header was 10, the filter bar 8,
    /// the field list 24 and table info 30, so changing the selection moved every value sideways.
    @Test("The row insets land the list on the pane's own edge")
    func listRowInsetsReachTheSharedEdge() {
        let plainLeading: CGFloat = 8
        let plainTrailing: CGFloat = 9

        #expect(plainLeading + InspectorMetrics.listRowLeadingCorrection == InspectorMetrics.horizontalInset)
        #expect(plainTrailing + InspectorMetrics.listRowTrailingCorrection == InspectorMetrics.horizontalInset)
    }

    /// The corrections only work against `.plain`, whose inset is half of `intercellSpacing`.
    /// `.inset` spends a hard 16pt per side first, which is where the 24 came from, so a correction
    /// computed for `.plain` cannot be applied to it.
    @Test("The corrections are small, because .plain starts close to the edge")
    func correctionsAreSmall() {
        #expect(InspectorMetrics.listRowLeadingCorrection >= 0)
        #expect(InspectorMetrics.listRowTrailingCorrection >= 0)
        #expect(InspectorMetrics.listRowLeadingCorrection < 8)
        #expect(InspectorMetrics.listRowTrailingCorrection < 8)
    }

    /// The gap between two fields has to beat the gap inside one, by enough to see. The shipped
    /// pane was 5pt against 2pt: the same 2.5x ratio, but only 3pt of actual difference, so the
    /// fields read as one undifferentiated stack.
    @Test("A field is separated from the next by more than its own label is from its value")
    func fieldsGroupVisibly() {
        #expect(InspectorMetrics.betweenFields > InspectorMetrics.labelToValue)
        #expect(InspectorMetrics.betweenFields - InspectorMetrics.labelToValue >= 6)
    }

    /// The inset is a real margin, not a decoration. Apple's own inspectors at this width measure
    /// 7 to 13, so anything outside that band is not a native number.
    @Test("The inset sits in the band Apple's own inspectors use")
    func insetIsNative() {
        #expect(InspectorMetrics.horizontalInset >= 7)
        #expect(InspectorMetrics.horizontalInset <= 13)
    }

    /// At the pane's 270pt minimum the value column is what is left after both margins. It was
    /// 224pt. A 29-character `timestamptz` needs 233pt at the default Data Grid font, so the old
    /// margin was the reason a stored timestamp could not be read whole.
    @Test("The value column clears a full timestamp at the pane's minimum")
    func valueColumnFitsATimestamp() {
        let paneMinimum: CGFloat = 270
        let content = paneMinimum - (InspectorMetrics.horizontalInset * 2)
        let editorChrome: CGFloat = 12
        let advanceAtDefaultGridFont: CGFloat = 8.036

        #expect(content == 250)
        #expect((content - editorChrome) / advanceAtDefaultGridFont >= 29)
    }
}
