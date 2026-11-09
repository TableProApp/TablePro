import CoreGraphics

// The split items open at their minimums: AutosavingSplitView's preferred fractions set no first layout here
// (measured on macOS 27). A minimum also clamps a saved divider record, so raising one reaches existing windows.
internal enum TableHealthLayoutMetrics {
    // The longest check title, "Foreign Keys Without an Index", beside a two-digit count, measured.
    static let checksListMinimumWidth: CGFloat = 274
    static let checksListMaximumWidth: CGFloat = 360
    static let findingsMinimumWidth: CGFloat = 320

    // A 480pt window leaves the tab about 357pt under its toolbar, tab strip and pane bar (measured). The two panes
    // and the 1pt divider between them fit in that, or the window cannot shrink to its minimum.
    static let findingsMinimumHeight: CGFloat = 120
    static let previewMinimumHeight: CGFloat = 236

    // At the preview's minimum height: the SQL keeps 71pt with the detail and facts capped under it, and 159pt
    // with them beside it (measured).
    static let previewSQLMinimumHeight: CGFloat = 60
    static let previewSQLIdealWidth: CGFloat = 280
    static let previewAboutWidth: CGFloat = 280
    static let previewAboutMaximumHeight: CGFloat = 80

    // The pane bar at its narrowest, with the database name truncated and the filter at 120. Narrower than the
    // checks list and the findings table side by side: between the two the list collapses.
    static let tabMinimumWidth: CGFloat = 560
}
