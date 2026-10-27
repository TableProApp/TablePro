import AppKit

internal extension NSLayoutConstraint.Priority {
    static let splitPaneHolding = NSLayoutConstraint.Priority(260)
    // Below the other pane's `.defaultLow`, so this one takes the room when the split view resizes.
    static let splitPaneFlexible = NSLayoutConstraint.Priority(240)
}
