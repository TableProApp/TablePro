import Foundation
@testable import TableProMSSQLCore
import Testing

@Suite("MSSQL FreeTDS config file")
struct MSSQLFreeTDSConfigFileTests {
    private let directory: String
    private let file: MSSQLFreeTDSConfigFile

    init() throws {
        directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("mssql-config-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        file = MSSQLFreeTDSConfigFile(path: (directory as NSString).appendingPathComponent("freetds.conf"))
    }

    private func entry(
        _ host: String,
        port: Int = 1_433,
        encryption: MSSQLEncryptionLevel = .require
    ) throws -> MSSQLFreeTDSServerEntry {
        try MSSQLFreeTDSServerEntry(
            host: host,
            port: port,
            encryption: encryption,
            verification: .none,
            caCertificatePath: nil
        )
    }

    private func contents() -> String? {
        try? String(contentsOfFile: file.path, encoding: .utf8)
    }

    @Test("The entry is in the file while the body runs, and the file is gone after")
    func entryLivesForTheBody() throws {
        let server = try entry("db.example.com")
        let seen = try file.withEntry(server, waitingAtMost: 10) { contents() }

        #expect(seen == server.text)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Only the owner can read the file")
    func fileIsPrivate() throws {
        let permissions = try file.withEntry(try entry("db.example.com"), waitingAtMost: 10) {
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        }

        #expect(permissions == 0o600)
    }

    @Test("Entries for two hosts are in the file together")
    func twoHostsSideBySide() throws {
        let first = try entry("alpha.example.com", encryption: .request)
        let second = try entry("beta.example.com", encryption: .require)

        let seen = try file.withEntry(first, waitingAtMost: 10) {
            try file.withEntry(second, waitingAtMost: 10) { contents() }
        }

        #expect(seen?.contains(first.text) == true)
        #expect(seen?.contains(second.text) == true)
    }

    @Test("A second holder of the same entry keeps it in the file until both are done")
    func sharedEntryOutlivesTheInnerHolder() throws {
        let server = try entry("db.example.com")

        let afterInner = try file.withEntry(server, waitingAtMost: 10) {
            try file.withEntry(server, waitingAtMost: 10) {}
            return contents()
        }

        #expect(afterInner == server.text)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Host names that differ only in case are one entry, as libtds reads them")
    func caseInsensitiveNames() async throws {
        let lower = try entry("db.example.com", encryption: .request)
        let upper = try entry("DB.example.com", encryption: .require)
        let file = file
        let order = OrderLog()
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)

        let holder = runOnOwnThread {
            try? file.withEntry(lower, waitingAtMost: 10) {
                order.append("lower in")
                holding.open()
                released.wait()
                order.append("lower out")
            }
        }
        await holding.wait()
        let waiter = runOnOwnThread {
            try? file.withEntry(upper, waitingAtMost: 10) { order.append("upper in") }
        }
        try await Task.sleep(for: .milliseconds(200))
        released.signal()
        await holder.wait()
        await waiter.wait()

        #expect(order.entries == ["lower in", "lower out", "upper in"])
    }

    @Test("A different entry for a host waits for the first dbopen, then finds its own settings")
    func conflictingEntryWaits() async throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let file = file
        let order = OrderLog()
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)
        let seenByEncrypted = Box<String?>(nil)

        let holder = runOnOwnThread {
            try? file.withEntry(plain, waitingAtMost: 10) {
                order.append("plain in")
                holding.open()
                released.wait()
                order.append("plain out")
            }
        }
        await holding.wait()
        let waiter = runOnOwnThread {
            try? file.withEntry(encrypted, waitingAtMost: 10) {
                order.append("encrypted in")
                seenByEncrypted.value = contents()
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(order.entries == ["plain in"])
        released.signal()
        await holder.wait()
        await waiter.wait()

        #expect(order.entries == ["plain in", "plain out", "encrypted in"])
        #expect(seenByEncrypted.value == encrypted.text)
    }

    @Test("A connect to another host does not wait on one that has not returned")
    func otherHostsDoNotWait() async throws {
        let slow = try entry("slow.example.com")
        let fast = try entry("fast.example.com")
        let file = file
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)

        let holder = runOnOwnThread {
            try? file.withEntry(slow, waitingAtMost: 10) {
                holding.open()
                released.wait()
            }
        }
        await holding.wait()
        let ranWhileSlowHeld = try file.withEntry(fast, waitingAtMost: 10) { contents()?.contains(fast.text) == true }
        released.signal()
        await holder.wait()

        #expect(ranWhileSlowHeld)
    }

    @Test("Connects to two ports on one address, as every SSH tunnel is, do not wait on each other")
    func portsOnOneAddressDoNotWait() async throws {
        let silent = try entry("127.0.0.1", port: 50_001)
        let live = try entry("127.0.0.1", port: 50_002, encryption: .request)
        let file = file
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)
        let seen = Box<String?>(nil)

        let silentConnect = runOnOwnThread {
            try? file.withEntry(silent, waitingAtMost: 10) {
                holding.open()
                released.wait()
            }
        }
        await holding.wait()
        let liveConnect = runOnOwnThread {
            try? file.withEntry(live, waitingAtMost: 10) { seen.value = contents() }
        }
        let liveRanWhileSilentHeld = await liveConnect.opens(within: .seconds(2))
        released.signal()
        await silentConnect.wait()
        await liveConnect.wait()

        #expect(liveRanWhileSilentHeld)
        #expect(seen.value?.contains(silent.text) == true)
        #expect(seen.value?.contains(live.text) == true)
    }

    @Test("A connect waiting for a name goes before a later one that matches the entry holding it")
    func waitingEntryIsNotOvertaken() async throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let file = file
        let order = OrderLog()
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)

        let holder = runOnOwnThread {
            try? file.withEntry(plain, waitingAtMost: 10) {
                order.append("first plain in")
                holding.open()
                released.wait()
                order.append("first plain out")
            }
        }
        await holding.wait()
        let encryptedConnect = runOnOwnThread {
            try? file.withEntry(encrypted, waitingAtMost: 10) { order.append("encrypted in") }
        }
        #expect(await eventually { file.waitingConnections(named: "db.example.com") == 1 })
        let secondPlainConnect = runOnOwnThread {
            try? file.withEntry(plain, waitingAtMost: 10) { order.append("second plain in") }
        }
        #expect(await eventually { file.waitingConnections(named: "db.example.com") == 2 })
        #expect(order.entries == ["first plain in"])
        released.signal()
        await holder.wait()
        await encryptedConnect.wait()
        await secondPlainConnect.wait()

        #expect(order.entries == ["first plain in", "first plain out", "encrypted in", "second plain in"])
    }

    @Test("A connect that cannot have the name in time gives up with the reason and leaves the line")
    func boundedWaitGivesUp() async throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let file = file
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)

        let holder = runOnOwnThread {
            try? file.withEntry(plain, waitingAtMost: 10) {
                holding.open()
                released.wait()
            }
        }
        await holding.wait()
        #expect(throws: MSSQLFreeTDSConfigError.nameInUse("db.example.com")) {
            try file.withEntry(encrypted, waitingAtMost: 0.2) {}
        }
        let waitingAfterGivingUp = file.waitingConnections(named: "db.example.com")
        let joinedTheHolder = try file.withEntry(plain, waitingAtMost: 0.2) { true }
        released.signal()
        await holder.wait()

        #expect(waitingAfterGivingUp == 0)
        #expect(joinedTheHolder)
    }

    @Test("A connect whose caller gave up leaves the line as soon as the waits are interrupted")
    func abandonedWaitLeavesTheLine() async throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let file = file
        let holding = Latch()
        let released = DispatchSemaphore(value: 0)
        let abandoned = Box(false)
        let waiterError = Box<Error?>(nil)
        let ran = Box(false)

        let holder = runOnOwnThread {
            try? file.withEntry(plain, waitingAtMost: 10) {
                holding.open()
                released.wait()
            }
        }
        await holding.wait()
        let waiter = runOnOwnThread {
            do {
                try file.withEntry(encrypted, waitingAtMost: 30, givingUpWhen: { abandoned.value }) { ran.value = true }
            } catch {
                waiterError.value = error
            }
        }
        #expect(await eventually { file.waitingConnections(named: "db.example.com") == 1 })
        abandoned.value = true
        file.interruptWaits()
        let leftInTime = await waiter.opens(within: .seconds(2))
        released.signal()
        await holder.wait()
        await waiter.wait()

        #expect(leftInTime)
        #expect(waiterError.value is CancellationError)
        #expect(!ran.value)
        #expect(file.waitingConnections(named: "db.example.com") == 0)
    }

    @Test("A file that cannot be written fails the connect and runs nothing")
    func unwritableFileThrows() throws {
        let missing = MSSQLFreeTDSConfigFile(path: (directory as NSString).appendingPathComponent("no/such/freetds.conf"))
        var ran = false

        #expect(throws: MSSQLFreeTDSConfigError.self) {
            try missing.withEntry(try entry("db.example.com"), waitingAtMost: 10) { ran = true }
        }
        #expect(!ran)
    }
}

private func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func runOnOwnThread(_ work: @escaping @Sendable () -> Void) -> Latch {
    let finished = Latch()
    let thread = Thread {
        work()
        finished.open()
    }
    thread.start()
    return finished
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var opened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    func open() {
        lock.lock()
        isOpen = true
        let released = waiters
        waiters = []
        lock.unlock()
        for waiter in released {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isOpen else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func opens(within limit: Duration) async -> Bool {
        await eventually(within: limit) { opened }
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ entry: String) {
        lock.lock()
        recorded.append(entry)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
