import CMariaDB
import Foundation
import os
import TableProMySQLCore

// Which statement a kill is for. A session runs one statement at a time, so a kill is taken only for the statement
// in flight; one asked for before its statement is sent, or after it ends, is dropped and never reaches the next one.
nonisolated struct MySQLKillRequests: Equatable, Sendable {
    private var lastStatement: UInt64 = 0
    private(set) var inFlight: UInt64?
    private var killRequested: UInt64?
    private var killDelivered: UInt64?
    private var killCollected: UInt64?
    private var lastLeft: UInt64?

    mutating func reserve() -> UInt64 {
        lastStatement &+= 1
        return lastStatement
    }

    mutating func sent(_ statement: UInt64) {
        inFlight = statement
    }

    mutating func finished(_ statement: UInt64, interrupted: Bool) {
        if interrupted { killCollected = statement }
        guard inFlight == statement else { return }
        inFlight = nil
    }

    mutating func detach() {
        inFlight = nil
        killDelivered = nil
        killCollected = nil
    }

    // Once per statement: a second kill could land after the first stopped it and stop the next statement instead.
    mutating func kill(_ statement: UInt64) -> Bool {
        guard inFlight == statement, killRequested != statement else { return false }
        killRequested = statement
        return true
    }

    mutating func readerLeft(_ statement: UInt64) {
        lastLeft = statement
    }

    // Stop names no statement, so it takes the one in flight only when that is the one whose reader left last: the
    // editor's own, never a statement another surface is still reading.
    mutating func killLeftInFlight() -> UInt64? {
        guard let statement = inFlight, lastLeft == statement, kill(statement) else { return nil }
        return statement
    }

    func isInFlight(_ statement: UInt64) -> Bool {
        inFlight == statement
    }

    mutating func delivered(_ statement: UInt64) {
        killDelivered = statement
    }

    // Order-independent: the kill is recorded from its own queue while its statement reads the interruption on the
    // actor. Clears the record either way.
    mutating func takeLatchedKill() -> Bool {
        defer {
            killDelivered = nil
            killCollected = nil
        }
        guard let statement = killDelivered else { return false }
        return killCollected != statement
    }
}

// The kill statement for a session, as the Mac plugin's MySQLKillTarget spells it. Nil where only `KILL <id>`, which
// ends the session, would stop the statement, and for Databend, whose session id this driver never reads.
nonisolated enum MySQLKillStatement {
    static func text(
        flavor: MySQLServerFlavor,
        banner: String?,
        threadId: UInt,
        tidbConnectionId: UInt64?
    ) -> String? {
        guard MySQLServerVersion.canStopStatementAlone(banner: banner, flavor: flavor) else { return nil }
        switch flavor {
        case .tidb:
            if let tidbConnectionId { return "KILL TIDB QUERY \(tidbConnectionId)" }
            return threadId > 0 ? "KILL QUERY \(threadId)" : nil
        case .databend:
            return nil
        case .mysql, .mariadb, .oceanbase, .starrocks:
            return threadId > 0 ? "KILL QUERY \(threadId)" : nil
        }
    }

    // Measured on the Mac: MySQL 5.5 and 5.6 and MariaDB 5.5 keep a kill that lands on an idle session and fail the
    // next statement with 1317. The other engines are unmeasured, so none gets a statement inserted on a guess.
    static func absorbsLatchedKill(flavor: MySQLServerFlavor) -> Bool {
        switch flavor {
        case .mysql, .mariadb:
            return true
        case .tidb, .databend, .oceanbase, .starrocks:
            return false
        }
    }
}

// The token the session signed in with serves a kill while it is young, because a mint can be an HTTPS round trip the
// next statement waits behind. Past ten minutes, five short of an RDS token's fifteen, a kill mints its own and later
// kills reuse that one the same way. The age runs from the connect, which comes after the tunnel and any prompts it
// raised, so a reused token can be older than it looks; the server's refusal of one is what settles it.
nonisolated final class MySQLKillSignIn: @unchecked Sendable {
    static let reuseWindow: Duration = .seconds(600)
    private static let mintTimeout: DispatchTimeInterval = .seconds(5)

    nonisolated struct Credential: Equatable, Sendable {
        let password: String
        // Handed out on its age alone, so a refusal means a mint could still sign the kill in.
        let isReused: Bool
    }

    nonisolated private struct NoToken: Error {}

    private let lock = NSLock()
    private let stopwatch: @Sendable () -> @Sendable () -> Duration
    private let refresh: (@Sendable () async throws -> String?)?
    private var token: String
    private var age: @Sendable () -> Duration

    init(password: String, refresh: (@Sendable () async throws -> String?)?, clock: any Clock<Duration>) {
        stopwatch = Self.stopwatches(on: clock)
        self.refresh = refresh
        token = password
        age = stopwatch()
    }

    // On the kill queue, never a Swift concurrency thread, so it may wait for the mint.
    func credential() -> Credential {
        let (current, currentAge) = lock.withLock { (token, age()) }
        guard refresh != nil else { return Credential(password: current, isReused: false) }
        guard currentAge >= Self.reuseWindow else { return Credential(password: current, isReused: true) }
        return Credential(password: mint() ?? current, isReused: false)
    }

    // The server refused `refused`, a token handed out on its age. One mint replaces it, unless another kill already did.
    func passwordAfterRefusal(of refused: String) -> String? {
        let current = lock.withLock { token }
        guard current == refused else { return current }
        return mint()
    }

    private func mint() -> String? {
        guard let refresh else { return nil }
        let mintStarted = stopwatch()
        let minted = MySQLBlockingPasswordRefresh.wait(
            for: {
                guard let fresh = try await refresh() else { throw NoToken() }
                return fresh
            },
            timeout: Self.mintTimeout
        )
        guard let minted else { return nil }
        lock.withLock {
            token = minted
            age = mintStarted
        }
        return minted
    }

    // Each call starts a new one: the time since that call.
    private static func stopwatches<C: Clock<Duration>>(on clock: C) -> @Sendable () -> @Sendable () -> Duration {
        {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }
}

// The way back to a server a statement is running on, repeating the transport and TLS the session actually got.
nonisolated struct MySQLKillDial: Sendable {
    let host: String
    let port: UInt32
    let user: String
    let signIn: MySQLKillSignIn
    let ssl: DriverSSLConfiguration
    let policy: MySQLTLSPolicy
    let serverName: MySQLTLSServerName?
    let signsInWithToken: Bool

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLStatementKiller")
    private static let timeoutSeconds: UInt32 = 5
    private static let accessDeniedCode: UInt32 = 1_045

    nonisolated private enum SignInAttempt {
        case connected(UnsafeMutablePointer<MYSQL>)
        case refused(code: UInt32, message: String)
    }

    func send(_ statement: String) -> Bool {
        let credential = signIn.credential()
        var attempt = open(signingInWith: credential.password)
        if case .refused(Self.accessDeniedCode, _) = attempt, credential.isReused,
           let fresh = signIn.passwordAfterRefusal(of: credential.password) {
            attempt = open(signingInWith: fresh)
        }
        let handle: UnsafeMutablePointer<MYSQL>
        switch attempt {
        case .connected(let connected):
            handle = connected
        case .refused(_, let message):
            Self.logger.warning("\(statement, privacy: .private) could not connect: \(message, privacy: .private)")
            return false
        }
        defer { mysql_close(handle) }
        guard mysql_real_query(handle, statement, UInt(statement.utf8.count)) == 0 else {
            Self.logger.warning("\(statement, privacy: .private) was refused: \(Self.failure(of: handle), privacy: .private)")
            return false
        }
        return true
    }

    // A refused sign-in leaves its handle closed, so a second try opens its own.
    private func open(signingInWith password: String) -> SignInAttempt {
        guard let handle = mysql_init(nil) else { return .refused(code: 0, message: "mysql_init failed") }
        MySQLDialOptions.apply(
            to: handle,
            policy: policy,
            ssl: ssl,
            serverName: serverName,
            signsInWithToken: signsInWithToken,
            connectSeconds: Self.timeoutSeconds,
            socketSeconds: Self.timeoutSeconds
        )
        let connected = withExtendedLifetime(serverName) {
            mysql_real_connect(handle, host, user, password, nil, port, nil, 0) != nil
        }
        guard connected else {
            let attempt = SignInAttempt.refused(code: mysql_errno(handle), message: Self.failure(of: handle))
            mysql_close(handle)
            return attempt
        }
        return .connected(handle)
    }

    private static func failure(of handle: UnsafeMutablePointer<MYSQL>) -> String {
        let code = mysql_errno(handle)
        guard let text = mysql_error(handle) else { return "error \(code)" }
        return "\(code) \(String(cString: text))"
    }
}

nonisolated struct MySQLSessionKill: Sendable {
    let statement: String
    let absorbsLatchedKill: Bool
    // TiDB drops a session a kill lands on once the statement has ended, so only Stop kills there, as on the Mac.
    let killsWhenReaderLeaves: Bool
    let dial: MySQLKillDial
}

// The actor sits blocked in Connector/C for as long as a statement runs, so Stop reaches the server from here, over a
// second connection. The lock is never held across a network call: opening that connection is a TCP connect, a TLS
// handshake and a sign-in.
nonisolated final class MySQLStatementKiller: @unchecked Sendable {
    private typealias Accepted = (statement: UInt64, target: MySQLSessionKill)

    private let queue = DispatchQueue(label: "com.TablePro.mobile.mysql.kill", qos: .userInitiated)
    private let lock = NSLock()
    private let pending = DispatchGroup()
    private var target: MySQLSessionKill?
    private var requests = MySQLKillRequests()

    func attach(_ target: MySQLSessionKill?) {
        lock.withLock { self.target = target }
    }

    func detach() {
        lock.withLock {
            target = nil
            requests.detach()
        }
    }

    func reserve() -> UInt64 {
        lock.withLock { requests.reserve() }
    }

    // A kill still on its way could stop the statement about to go out, so it is waited for first.
    func collectLatchedKill() -> Bool {
        pending.wait()
        return lock.withLock { requests.takeLatchedKill() && target?.absorbsLatchedKill == true }
    }

    func sent(_ statement: UInt64) {
        lock.withLock { requests.sent(statement) }
    }

    func finished(_ statement: UInt64, interrupted: Bool) {
        lock.withLock { requests.finished(statement, interrupted: interrupted) }
    }

    // A page change, a closed screen or Stop: the reader of the stream left while its statement may still run.
    func readerLeft(_ statement: UInt64) {
        deliver(lock.withLock { () -> Accepted? in
            requests.readerLeft(statement)
            guard target?.killsWhenReaderLeaves == true else { return nil }
            return accepted(requests.kill(statement) ? statement : nil)
        })
    }

    func stop() {
        deliver(lock.withLock { accepted(requests.killLeftInFlight()) })
    }

    // The socket timeout gave up on a statement the server is still running, and the handle can no longer reach it.
    func killOrphan() {
        guard let target = lock.withLock({ self.target }) else { return }
        queue.async {
            _ = target.dial.send(target.statement)
        }
    }

    // Entered in the same critical section that takes the kill, so a statement that ends right after still finds the
    // kill pending and the next one waits for it.
    private func accepted(_ statement: UInt64?) -> Accepted? {
        guard let statement, let target = self.target else { return nil }
        pending.enter()
        return (statement, target)
    }

    private func deliver(_ accepted: Accepted?) {
        guard let accepted else { return }
        queue.async { [self] in
            defer { pending.leave() }
            guard lock.withLock({ requests.isInFlight(accepted.statement) }) else { return }
            guard accepted.target.dial.send(accepted.target.statement) else { return }
            lock.withLock { requests.delivered(accepted.statement) }
        }
    }
}
