import Foundation
import Testing

@testable import TableProSSHTransport

struct KnownHostsFileTests {
    private static let host = "[db.example.com]:22"

    private func key(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: 32)
    }

    private func line(_ host: String, _ keyType: String, _ key: Data) -> String {
        "\(host) \(keyType) \(key.base64EncodedString())"
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("known_hosts_\(UUID().uuidString)")
    }

    @Test("A missing file is an empty store")
    func missingFileIsEmpty() throws {
        let file = try KnownHostsFile.load(from: temporaryURL())

        #expect(file.entries.isEmpty)
        #expect(file.match(host: Self.host, keyType: "ssh-ed25519", keyData: key(1)) == .unknown)
    }

    @Test("A file that exists but cannot be read throws instead of reading as empty")
    func unreadableFileThrows() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(line(Self.host, "ssh-ed25519", key(1)).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let error = #expect(throws: CocoaError.self) {
            _ = try KnownHostsFile.load(from: url)
        }
        #expect(error?.code == .fileReadNoPermission)
    }

    @Test("A file that is not UTF-8 throws instead of reading as empty")
    func undecodableFileThrows() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x5B, 0xFF, 0xFE, 0x0A]).write(to: url)

        let error = #expect(throws: CocoaError.self) {
            _ = try KnownHostsFile.load(from: url)
        }
        #expect(error?.code == .fileReadInapplicableStringEncoding)
    }

    @Test("A stored key matches, and another key for the host is a change")
    func storedKeyMatches() {
        let file = KnownHostsFile(contents: line(Self.host, "ssh-ed25519", key(1)) + "\n")

        #expect(file.match(host: Self.host, keyType: "ssh-ed25519", keyData: key(1)) == .trusted)
        #expect(file.match(host: Self.host, keyType: "ssh-ed25519", keyData: key(2)) == .changed(storedKey: key(1)))
        #expect(file.match(host: Self.host, keyType: "ssh-rsa", keyData: key(2)) == .changed(storedKey: key(1)))
        #expect(file.match(host: "[db.example.com]:2222", keyType: "ssh-ed25519", keyData: key(1)) == .unknown)
    }

    @Test("A line whose key cannot be parsed keeps its host from reading as new", arguments: [
        "[db.example.com]:22 ssh-ed25519 !!not-base64!!",
        "[db.example.com]:22 ssh-ed25519",
        "[db.example.com]:22",
    ])
    func unparsedLineIsNotANewHost(unparsed: String) {
        let file = KnownHostsFile(contents: unparsed + "\n" + line("[other.example.com]:22", "ssh-ed25519", key(3)) + "\n")

        #expect(file.match(host: Self.host, keyType: "ssh-ed25519", keyData: key(1)) == .unreadable)
        #expect(file.match(host: "[new.example.com]:22", keyType: "ssh-ed25519", keyData: key(1)) == .unknown)
        #expect(file.entries.map { $0.host } == ["[other.example.com]:22"])
    }

    @Test("Trusting a host writes back every line it did not replace, as it was read")
    func trustKeepsOtherLines() {
        let unparsed = "[broken.example.com]:22 ssh-ed25519 !!not-base64!!"
        let comment = "# added by hand"
        let commented = line("[commented.example.com]:22", "ssh-rsa", key(4)) + " laptop"
        let replaced = line(Self.host, "ssh-ed25519", key(1))
        var file = KnownHostsFile(contents: [unparsed, comment, commented, replaced].joined(separator: "\n") + "\n")

        file.trust(host: Self.host, keyType: "ssh-ed25519", keyData: key(2))

        let expected = [unparsed, comment, commented, line(Self.host, "ssh-ed25519", key(2))]
        #expect(file.contents == expected.joined(separator: "\n") + "\n")
        #expect(file.match(host: "[commented.example.com]:22", keyType: "ssh-rsa", keyData: key(4)) == .trusted)
    }

    @Test("Trusting a second key type keeps the first")
    func trustAddsKeyType() {
        var file = KnownHostsFile(contents: line(Self.host, "ssh-rsa", key(1)) + "\n")

        file.trust(host: Self.host, keyType: "ssh-ed25519", keyData: key(2))

        #expect(file.match(host: Self.host, keyType: "ssh-rsa", keyData: key(1)) == .trusted)
        #expect(file.match(host: Self.host, keyType: "ssh-ed25519", keyData: key(2)) == .trusted)
    }

    @Test("Removing a host drops every line naming it, the unparsed ones too")
    func removeDropsEveryLineForTheHost() {
        let kept = line("[other.example.com]:22", "ssh-ed25519", key(3))
        var file = KnownHostsFile(contents: [
            line(Self.host, "ssh-rsa", key(1)),
            "[db.example.com]:22 ssh-ed25519 !!not-base64!!",
            kept,
        ].joined(separator: "\n"))

        let removed = file.remove(host: Self.host)
        let removedAgain = file.remove(host: Self.host)

        #expect(removed)
        #expect(!removedAgain)
        #expect(file.contents == kept + "\n")
        #expect(file.match(host: Self.host, keyType: "ssh-rsa", keyData: key(1)) == .unknown)
    }

    @Test("Lines ending in a carriage return or split by tabs still parse")
    func lenientWhitespace() {
        let file = KnownHostsFile(contents: "\(Self.host)\tssh-ed25519\t\(key(1).base64EncodedString())\r\n")

        #expect(file.match(host: Self.host, keyType: "ssh-ed25519", keyData: key(1)) == .trusted)
    }

    @Test("An empty store writes an empty file")
    func emptyContents() {
        #expect(KnownHostsFile().contents.isEmpty)
        #expect(KnownHostsFile(contents: "\n\n").contents.isEmpty)
    }
}
