import CoreGraphics

// The split items open at their minimums: AutosavingSplitView's preferred fractions set no first layout here
// (measured on macOS 27). A minimum also clamps a saved divider record, so raising one reaches existing windows.
internal enum TableHealthLayoutMetrics {
    // The longest check title, "Foreign Keys Without an Index", beside a two-digit count, measured.
    static let checksListMinimumWidth: CGFloat = 274
    static let checksListMaximumWidth: CGFloat = 360
    static let findingsMinimumWidth: CGFloat = 320
    static let findingsMinimumHeight: CGFloat = 140
    // Leaves the fix SQL about 140pt under the title, detail line and note.
    static let previewMinimumHeight: CGFloat = 240

    // Below this the SQL and the facts beside it stop fitting, and the facts move under the SQL.
    static let previewSQLIdealWidth: CGFloat = 280
    static let previewFactsWidth: CGFloat = 220

    // The pane bar at its narrowest, with the database name truncated and the filter at 120. Narrower than the
    // checks list and the findings table side by side: between the two the list collapses.
    static let tabMinimumWidth: CGFloat = 560
}
