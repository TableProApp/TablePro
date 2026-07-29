import CoreGraphics

internal enum UsersRolesLayoutMetrics {
    static let principalListMinimumWidth: CGFloat = 200
    static let principalListMaximumWidth: CGFloat = 520
    static let principalDetailMinimumWidth: CGFloat = 560

    static let privilegeScopeMinimumWidth: CGFloat = 200
    static let privilegeScopeMaximumWidth: CGFloat = 640
    static let privilegeChecklistMinimumWidth: CGFloat = 300

    static var tabMinimumWidth: CGFloat { principalDetailMinimumWidth }
}
