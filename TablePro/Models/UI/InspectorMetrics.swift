//
//  InspectorMetrics.swift
//  TablePro
//

import Foundation

/// The inspector pane's edge and its vertical rhythm, in one place because the pane has four
/// surfaces and they must agree: the header, the filter bar, the field list and the table-info
/// state. They did not. Measured at the pane's 270pt minimum, content sat at 10pt in the header,
/// 8pt in the filter bar, 24pt in the field list and 30pt in table info, so switching a selection
/// moved every value sideways.
///
/// The macOS HIG publishes no point values for margins or spacing; that was checked across its
/// layout, sidebars, panels, split-views, lists-and-tables, windows and toolbars pages and came
/// back empty. So these come from what Apple and the two AppKit database clients actually ship,
/// measured by an accessibility walk and by decoding their nibs:
///
/// | surface                          | inset |
/// | -------------------------------- | ----- |
/// | System Settings, 232pt pane      | 10/10 |
/// | TablePlus row inspector          | 10/10 |
/// | Postico 2 row view               |  7/7  |
/// | Xcode inspector chrome           |  7/7  |
/// | Finder Get Info, 265pt           | 13/13 |
///
/// 10 is what System Settings uses with its search field and its list rows on one edge, which is
/// exactly this pane's shape, and it is independently where TablePlus puts its filter field and its
/// cells. It is also already the header's own inset, and the assistant that shares the split item
/// with it.
///
/// A native list contributes no vertical gap of its own: `NSTableView.intercellSpacing.height` is
/// 0, every Apple list measured has zero gap, and SwiftUI's macOS List has no row spacing either
/// (the 4pt one appears to add is the 24pt `defaultMinListRowHeight` floor). Padding belongs inside
/// the row, which is why `betweenFields` is spent there and `listRowInsets` carries none of it.
/// Splitting it across both is what made a nominal 8 arrive as 12 to 14.
internal enum InspectorMetrics {
    /// The one edge every surface in the pane sits on.
    internal static let horizontalInset: CGFloat = 10

    /// Between one field and the next. Against `labelToValue` this is what separates the fields
    /// into groups; the absolute difference matters more than the ratio, and 4pt against 5pt read
    /// as one undifferentiated stack.
    internal static let betweenFields: CGFloat = 10

    /// From a field's own name line to its value. Postico 2 pins exactly this pair at 4pt.
    internal static let labelToValue: CGFloat = 4

    /// `List(.plain)` lands its rows at half of `intercellSpacing`, measured 8pt leading and 9pt
    /// trailing at the default 17. These carry the row content the rest of the way onto
    /// `horizontalInset`, and square the 1pt asymmetry AppKit leaves behind.
    ///
    /// `.inset` cannot be corrected this way: it spends a hard 16pt per side before any
    /// `listRowInsets` is consulted, which is where the pane's 24pt came from.
    internal static let listRowLeadingCorrection: CGFloat = horizontalInset - 8
    internal static let listRowTrailingCorrection: CGFloat = horizontalInset - 9
}
