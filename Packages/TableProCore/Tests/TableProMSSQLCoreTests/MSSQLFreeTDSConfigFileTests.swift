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
    func caseInsensitiveNames() throws {
        let lower = try entry("db.example.com", encryption: .request)
        let upper = try entry("DB.example.com", encryption: .require)
        let order = OrderLog()
        let released = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try? file.withEntry(lower, waitingAtMost: 10) {
                order.append("lower in")
                holding.signal()
                released.wait()
                order.append("lower out")
            }
        }
        holding.wait()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? file.withEntry(upper, waitingAtMost: 10) { order.append("upper in") }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        released.signal()
        done.wait()

        #expect(order.entries == ["lower in", "lower out", "upper in"])
    }

    @Test("A different entry for a host waits for the first dbopen, then finds its own settings")
    func conflictingEntryWaits() throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let order = OrderLog()
        let holding = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let seenByEncrypted = Box<String?>(nil)

        DispatchQueue.global().async {
            try? file.withEntry(plain, waitingAtMost: 10) {
                order.append("plain in")
                holding.signal()
                released.wait()
                order.append("plain out")
            }
        }
        holding.wait()
        DispatchQueue.global().async {
            try? file.withEntry(encrypted, waitingAtMost: 10) {
                order.append("encrypted in")
                seenByEncrypted.value = contents()
            }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(order.entries == ["plain in"])
        released.signal()
        done.wait()

        #expect(order.entries == ["plain in", "plain out", "encrypted in"])
        #expect(seenByEncrypted.value == encrypted.text)
    }

    @Test("A connect to another host does not wait on one that has not returned")
    func otherHostsDoNotWait() throws {
        let slow = try entry("slow.example.com")
        let fast = try entry("fast.example.com")
        let holding = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try? file.withEntry(slow, waitingAtMost: 10) {
                holding.signal()
                released.wait()
            }
            finished.signal()
        }
        holding.wait()
        let ranWhileSlowHeld = try file.withEntry(fast, waitingAtMost: 10) { contents()?.contains(fast.text) == true }
        released.signal()
        finished.wait()

        #expect(ranWhileSlowHeld)
    }

    @Test("Connects to two ports on one address, as every SSH tunnel is, do not wait on each other")
    func portsOnOneAddressDoNotWait() throws {
        let silent = try entry("127.0.0.1", port: 50_001)
        let live = try entry("127.0.0.1", port: 50_002, encryption: .request)
        let holding = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let silentFinished = DispatchSemaphore(value: 0)
        let liveFinished = DispatchSemaphore(value: 0)
        let seen = Box<String?>(nil)

        DispatchQueue.global().async {
            try? file.withEntry(silent, waitingAtMost: 10) {
                holding.signal()
                released.wait()
            }
            silentFinished.signal()
        }
        holding.wait()
        DispatchQueue.global().async {
            try? file.withEntry(live, waitingAtMost: 10) { seen.value = contents() }
            liveFinished.signal()
        }
        let liveRanWhileSilentHeld = liveFinished.wait(timeout: .now() + 2) == .success
        released.signal()
        silentFinished.wait()
        if !liveRanWhileSilentHeld {
            liveFinished.wait()
        }

        #expect(liveRanWhileSilentHeld)
        #expect(seen.value?.contains(silent.text) == true)
        #expect(seen.value?.contains(live.text) == true)
    }

    @Test("A connect waiting for a name goes before a later one that matches the entry holding it")
    func waitingEntryIsNotOvertaken() throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let order = OrderLog()
        let holding = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try? file.withEntry(plain, waitingAtMost: 10) {
                order.append("first plain in")
                holding.signal()
                released.wait()
                order.append("first plain out")
            }
        }
        holding.wait()
        DispatchQueue.global().async {
            try? file.withEntry(encrypted, waitingAtMost: 10) { order.append("encrypted in") }
            done.signal()
        }
        #expect(waitUntil { file.waitingConnections(named: "db.example.com") == 1 })
        DispatchQueue.global().async {
            try? file.withEntry(plain, waitingAtMost: 10) { order.append("second plain in") }
            done.signal()
        }
        #expect(waitUntil { file.waitingConnections(named: "db.example.com") == 2 })
        #expect(order.entries == ["first plain in"])
        released.signal()
        done.wait()
        done.wait()

        #expect(order.entries == ["first plain in", "first plain out", "encrypted in", "second plain in"])
    }

    @Test("A connect that cannot have the name in time gives up with the reason and leaves the line")
    func boundedWaitGivesUp() throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let holding = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try? file.withEntry(plain, waitingAtMost: 10) {
                holding.signal()
                released.wait()
            }
            finished.signal()
        }
        holding.wait()
        #expect(throws: MSSQLFreeTDSConfigError.nameInUse("db.example.com")) {
            try file.withEntry(encrypted, waitingAtMost: 0.2) {}
        }
        let waitingAfterGivingUp = file.waitingConnections(named: "db.example.com")
        let joinedTheHolder = try file.withEntry(plain, waitingAtMost: 0.2) { true }
        released.signal()
        finished.wait()

        #expect(waitingAfterGivingUp == 0)
        #expect(joinedTheHolder)
    }

    @Test("A connect whose caller gave up leaves the line as soon as the waits are interrupted")
    func abandonedWaitLeavesTheLine() throws {
        let plain = try entry("db.example.com", encryption: .request)
        let encrypted = try entry("db.example.com", encryption: .require)
        let holding = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let abandoned = Box(false)
        let waiterError = Box<Error?>(nil)
        let ran = Box(false)

        DispatchQueue.global().async {
            try? file.withEntry(plain, waitingAtMost: 10) {
                holding.signal()
                released.wait()
            }
            holderFinished.signal()
        }
        holding.wait()
        DispatchQueue.global().async {
            do {
                try file.withEntry(encrypted, waitingAtMost: 30, givingUpWhen: { abandoned.value }) { ran.value = true }
            } catch {
                waiterError.value = error
            }
            waiterFinished.signal()
        }
        #expect(waitUntil { file.waitingConnections(named: "db.example.com") == 1 })
        abandoned.value = true
        file.interruptWaits()
        let leftInTime = waiterFinished.wait(timeout: .now() + 2) == .success
        released.signal()
        holderFinished.wait()
        if !leftInTime {
            waiterFinished.wait()
        }

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

private func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
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
