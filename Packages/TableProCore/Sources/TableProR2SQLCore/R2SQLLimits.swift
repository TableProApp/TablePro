import Foundation

public enum R2SQLLimits {
    public static let defaultLimit = 500
    public static let minLimit = 1
    public static let maxLimit = 10_000

    public static func clampLimit(_ limit: Int) -> Int {
        min(max(limit, minLimit), maxLimit)
    }
}
