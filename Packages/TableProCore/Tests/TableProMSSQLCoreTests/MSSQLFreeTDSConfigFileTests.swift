import Foundation
import TableProMSSQLCore
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
        let seen = try file.withEntry(server) { contents() }

        #expect(seen == server.text)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Only the owner can read the file")
    func fileIsPrivate() throws {
        let permissions = try file.withEntry(try entry("db.example.com")) {
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        }

        #expect(permissions == 0o600)
    }

    @Test("Entries for two hosts are in the file together")
    func twoHostsSideBySide() throws {
        let first = try entry("alpha.example.com", encryption: .request)
        let second = try entry("beta.example.com", encryption: .require)

        let seen = try file.withEntry(first) {
            try file.withEntry(second) { contents() }
        }

        #expect(seen?.contains(first.text) == true)
        #expect(seen?.contains(second.text) == true)
    }

    @Test("A second holder of the same entry keeps it in the file until both are done")
    func sharedEntryOutlivesTheInnerHolder() throws {
        let server = try entry("db.example.com")

        let afterInner = try file.withEntry(server) {
            try file.withEntry(server) {}
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
            try? file.withEntry(lower) {
                order.append("lower in")
                holding.signal()
                released.wait()
                order.append("lower out")
            }
        }
        holding.wait()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? file.withEntry(upper) { order.append("upper in") }
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
            try? file.withEntry(plain) {
                order.append("plain in")
                holding.signal()
                released.wait()
                order.append("plain out")
            }
        }
        holding.wait()
        DispatchQueue.global().async {
            try? file.withEntry(encrypted) {
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
            try? file.withEntry(slow) {
                holding.signal()
                released.wait()
            }
            finished.signal()
        }
        holding.wait()
        let ranWhileSlowHeld = try file.withEntry(fast) { contents()?.contains(fast.text) == true }
        released.signal()
        finished.wait()

        #expect(ranWhileSlowHeld)
    }

    @Test("A file that cannot be written fails the connect and runs nothing")
    func unwritableFileThrows() throws {
        let missing = MSSQLFreeTDSConfigFile(path: (directory as NSString).appendingPathComponent("no/such/freetds.conf"))
        var ran = false

        #expect(throws: MSSQLFreeTDSConfigError.self) {
            try missing.withEntry(try entry("db.example.com")) { ran = true }
        }
        #expect(!ran)
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
