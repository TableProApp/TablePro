import Foundation

public enum JsonRpcErrorCode {
    public static let parseError = -32_700
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603

    public static let headerMismatch = -32_020
    public static let missingRequiredClientCapability = -32_021
    public static let unsupportedProtocolVersion = -32_022

    public static let serverError = -33_000
    public static let sessionNotFound = -33_001
    public static let requestCancelled = -33_002
    public static let requestTimeout = -33_003
    public static let tooLarge = -33_005
    public static let serverDisabled = -33_006
    public static let forbidden = -33_007
    public static let expired = -33_008
    public static let unauthenticated = -33_009
    public static let rateLimited = -33_010

    public static let specificationReservedRange: ClosedRange<Int> = -32_099 ... -32_020
    public static let legacyImplementationRange: ClosedRange<Int> = -32_019 ... -32_000
    public static let tableProRange: ClosedRange<Int> = -33_099 ... -33_000

    public static func isSpecificationReserved(_ code: Int) -> Bool {
        specificationReservedRange.contains(code)
    }

    public static let specificationDefined: Set<Int> = [
        headerMismatch,
        missingRequiredClientCapability,
        unsupportedProtocolVersion
    ]
}
