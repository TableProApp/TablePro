import CoreGraphics

internal enum TableHealthLayoutMetrics {
    static let checksListMinimumWidth: CGFloat = 180
    static let checksListMaximumWidth: CGFloat = 280
    static let findingsMinimumWidth: CGFloat = 320
    static let findingsMinimumHeight: CGFloat = 160
    static let previewMinimumHeight: CGFloat = 150

    // The pane bar at its narrowest, with the database name truncated and the filter at 120: wider than the checks
    // list and the findings table need side by side, so the bar sets the floor.
    static let tabMinimumWidth: CGFloat = 560
}
