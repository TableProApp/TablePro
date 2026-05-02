import Foundation

public enum JsonRpcErrorCode {
    public static let parseError = -32_700
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603

    public static let serverError = -32_000
    public static let sessionNotFound = -32_001
    public static let requestCancelled = -32_002
    public static let requestTimeout = -32_003
    public static let resourceNotFound = -32_004
    public static let tooLarge = -32_005
    public static let serverDisabled = -32_006
    public static let forbidden = -32_007
    public static let expired = -32_008
    public static let unauthenticated = -32_009

    public static let serverErrorRange: ClosedRange<Int> = -32_099 ... -32_000
}
