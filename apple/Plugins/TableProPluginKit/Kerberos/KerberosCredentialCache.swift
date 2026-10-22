import Foundation

// GSS reads KRB5CCNAME on every call, and the variable is process-wide. Every driver holds this
// one lock across its GSS exchange, so a connect pointed at a private cache never lends that
// cache to a connect meant for the default one, in any plugin.
public enum KerberosCredentialCache {
    public struct WaitTimedOut: Error, Sendable {}

    private static let lock = NSLock()

    // Waits for another sign-in no longer than the caller's own connect deadline.
    public static func using<T>(_ cachePath: String?, until deadline: Date, _ body: () throws -> T) throws -> T {
        guard lock.lock(before: deadline) else { throw WaitTimedOut() }
        defer { lock.unlock() }
        guard let cachePath else { return try body() }
        let previous = getenv("KRB5CCNAME").map { String(cString: $0) }
        setenv("KRB5CCNAME", "FILE:\(cachePath)", 1)
        defer {
            if let previous {
                setenv("KRB5CCNAME", previous, 1)
            } else {
                unsetenv("KRB5CCNAME")
            }
        }
        return try body()
    }
}
