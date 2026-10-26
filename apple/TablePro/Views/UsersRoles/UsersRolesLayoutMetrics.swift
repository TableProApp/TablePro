import CoreGraphics

internal enum UsersRolesLayoutMetrics {
    static let principalListMinimumWidth: CGFloat = 200
    static let principalListMaximumWidth: CGFloat = 520
    /// What the detail's tab view takes from its width, its margin and its bezel, measured on macOS 27.
    static let principalDetailTabViewInset: CGFloat = 32
    static let principalDetailMinimumWidth: CGFloat = 560 + principalDetailTabViewInset

    static let privilegeScopeMinimumWidth: CGFloat = 200
    static let privilegeScopeMaximumWidth: CGFloat = 640
    static let privilegeChecklistMinimumWidth: CGFloat = 300

    static var tabMinimumWidth: CGFloat { principalDetailMinimumWidth }
}
