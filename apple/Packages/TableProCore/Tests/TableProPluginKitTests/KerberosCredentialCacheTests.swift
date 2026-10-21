import Foundation
import os
import TableProPluginKit
import Testing

@Suite(.serialized)
struct KerberosCredentialCacheTests {
    private var current: String? {
        getenv("KRB5CCNAME").map { String(cString: $0) }
    }

    private var soon: Date { Date().addingTimeInterval(5) }

    @Test("A private cache is the default only while the body runs")
    func privateCacheIsScoped() throws {
        let original = current
        defer { restore(original) }
        unsetenv("KRB5CCNAME")

        let inside = try KerberosCredentialCache.using("/tmp/tablepro-krb5-test", until: soon) { current }

        #expect(inside == "FILE:/tmp/tablepro-krb5-test")
        #expect(current == nil)
    }

    @Test("A cache the user set is put back afterwards, even when the body throws")
    func userCacheIsRestored() {
        let original = current
        defer { restore(original) }
        setenv("KRB5CCNAME", "API:user-cache", 1)

        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try KerberosCredentialCache.using("/tmp/tablepro-krb5-test", until: soon) { throw Failure() }
        }

        #expect(current == "API:user-cache")
    }

    @Test("No private cache leaves the default cache alone")
    func noCacheLeavesTheEnvironment() throws {
        let original = current
        defer { restore(original) }
        setenv("KRB5CCNAME", "API:user-cache", 1)

        let inside = try KerberosCredentialCache.using(nil, until: soon) { current }

        #expect(inside == "API:user-cache")
        #expect(current == "API:user-cache")
    }

    @Test("Concurrent sign-ins each see only their own cache, and one on the default cache sees none")
    func concurrentSignInsStayIsolated() {
        let original = current
        defer { restore(original) }
        unsetenv("KRB5CCNAME")

        let paths: [String?] = ["/tmp/tablepro-krb5-a", "/tmp/tablepro-krb5-b", nil]
        let mismatches = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 300) { iteration in
            let path = paths[iteration % paths.count]
            let expected = path.map { "FILE:\($0)" }
            do {
                let seen = try KerberosCredentialCache.using(path, until: Date().addingTimeInterval(10)) {
                    getenv("KRB5CCNAME").map { String(cString: $0) }
                }
                if seen != expected {
                    mismatches.withLock { $0 += 1 }
                }
            } catch {
                mismatches.withLock { $0 += 1 }
            }
        }

        #expect(mismatches.withLock { $0 } == 0)
        #expect(current == nil)
    }

    @Test("A sign-in that cannot get the lock by its deadline gives up instead of waiting it out")
    func waitEndsAtTheDeadline() throws {
        let held = LockHolder()
        let holder = Thread {
            _ = try? KerberosCredentialCache.using(nil, until: .distantFuture) {
                held.signalHeld()
                held.waitForRelease()
            }
        }
        holder.start()
        held.waitUntilHeld()
        defer { held.release() }

        #expect(throws: KerberosCredentialCache.WaitTimedOut.self) {
            try KerberosCredentialCache.using(nil, until: Date().addingTimeInterval(0.05)) {}
        }
    }

    private func restore(_ value: String?) {
        if let value {
            setenv("KRB5CCNAME", value, 1)
        } else {
            unsetenv("KRB5CCNAME")
        }
    }
}

private final class LockHolder: @unchecked Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func signalHeld() { held.signal() }
    func waitUntilHeld() { held.wait() }
    func waitForRelease() { released.wait() }
    func release() { released.signal() }
}
