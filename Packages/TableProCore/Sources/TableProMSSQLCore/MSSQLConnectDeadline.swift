import Dispatch

public struct MSSQLConnectDeadline: Sendable {
    private static let nanosecondsPerMillisecond: UInt64 = 1_000_000

    private let uptimeNanoseconds: UInt64

    public init(timeoutMilliseconds: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        let milliseconds = UInt64(max(1, timeoutMilliseconds))
        let maximumMilliseconds = (UInt64.max - now) / Self.nanosecondsPerMillisecond
        let duration = min(milliseconds, maximumMilliseconds) * Self.nanosecondsPerMillisecond
        uptimeNanoseconds = now + duration
    }

    public var remainingMilliseconds: Int {
        let now = DispatchTime.now().uptimeNanoseconds
        guard uptimeNanoseconds > now else { return 0 }
        let nanoseconds = uptimeNanoseconds - now
        let whole = nanoseconds / Self.nanosecondsPerMillisecond
        let rounded = whole + (nanoseconds.isMultiple(of: Self.nanosecondsPerMillisecond) ? 0 : 1)
        return Int(min(rounded, UInt64(Int.max)))
    }
}
