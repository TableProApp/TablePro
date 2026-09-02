//
//  SSHPublicKeyFileTests.swift
//  TableProTests
//
//  Reading the public half of an `IdentityFile` is what lets TablePro pick one key out of an
//  agent that holds thirty, so a `.pub` that fails to parse is the difference between a working
//  connection and "Too many authentication failures" (#2601).
//

import Foundation
import Testing

@testable import TablePro

/// Builds the SSH wire encodings both a `.pub` file and the agent protocol carry, so no fixture
/// is a hand-typed base64 string that has to be trusted.
enum SSHPublicKeyFixture {
    /// An SSH `string`: a big-endian length followed by that many bytes.
    static func wireString(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        let length = UInt32(bytes.count)
        return [
            UInt8(length >> 24 & 0xFF),
            UInt8(length >> 16 & 0xFF),
            UInt8(length >> 8 & 0xFF),
            UInt8(length & 0xFF),
        ] + bytes
    }

    /// A public key blob: its type, then whatever stands in for the key material.
    static func blob(type: String, seed: UInt8) -> Data {
        Data(wireString(type) + [UInt8](repeating: seed, count: 32))
    }

    static func line(type: String, seed: UInt8, comment: String = "alice@example.com") -> String {
        "\(type) \(blob(type: type, seed: seed).base64EncodedString()) \(comment)"
    }
}

@Suite("SSH public key file")
struct SSHPublicKeyFileTests {
    private static let ed25519 = "ssh-ed25519"
    private static let certificate = "ssh-ed25519-cert-v01@openssh.com"

    private static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-pubkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("A public key line parses into its type and wire blob")
    func parsesAPublicKeyLine() throws {
        let line = SSHPublicKeyFixture.line(type: Self.ed25519, seed: 1)
        let parsed = try #require(SSHPublicKeyFile.parse(publicKeyLine: line))

        #expect(parsed.keyType == Self.ed25519)
        #expect(parsed.blob == SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 1))
        #expect(parsed.isCertificate == false)
    }

    @Test("A certificate line reports itself as one")
    func recognisesACertificate() throws {
        let line = SSHPublicKeyFixture.line(type: Self.certificate, seed: 2)
        let parsed = try #require(SSHPublicKeyFile.parse(publicKeyLine: line))

        #expect(parsed.isCertificate)
    }

    @Test("A line whose blob does not describe the declared type is rejected")
    func rejectsATypeMismatch() {
        let blob = SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 3).base64EncodedString()

        #expect(SSHPublicKeyFile.parse(publicKeyLine: "ssh-rsa \(blob) alice") == nil)
    }

    @Test("A private key file is not a public key")
    func rejectsAPrivateKeyHeader() {
        #expect(SSHPublicKeyFile.parse(publicKeyLine: "-----BEGIN OPENSSH PRIVATE KEY-----") == nil)
        #expect(SSHPublicKeyFile.parse(publicKeyLine: "-----BEGIN RSA PRIVATE KEY-----") == nil)
    }

    @Test("A line with no base64 field is rejected")
    func rejectsAShortLine() {
        #expect(SSHPublicKeyFile.parse(publicKeyLine: "ssh-ed25519") == nil)
        #expect(SSHPublicKeyFile.parse(publicKeyLine: "") == nil)
    }

    @Test("Base64 that is not valid is rejected")
    func rejectsBadBase64() {
        #expect(SSHPublicKeyFile.parse(publicKeyLine: "ssh-ed25519 !!!notbase64!!! alice") == nil)
    }

    @Test("An identity file naming a .pub reads it directly")
    func readsAPubFileNamedDirectly() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.pub")
        try Self.write(SSHPublicKeyFixture.line(type: Self.ed25519, seed: 4) + "\n", to: path)

        let blobs = SSHPublicKeyFile.blobs(atIdentityPath: path.path)

        #expect(blobs.count == 1)
        #expect(blobs.first?.blob == SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 4))
    }

    @Test("An identity file naming a private key reads the .pub beside it")
    func fallsBackToTheSidecar() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_ed25519")
        try Self.write("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n", to: key)
        try Self.write(
            SSHPublicKeyFixture.line(type: Self.ed25519, seed: 5) + "\n",
            to: directory.appendingPathComponent("id_ed25519.pub")
        )

        let blobs = SSHPublicKeyFile.blobs(atIdentityPath: key.path)

        #expect(blobs.count == 1)
        #expect(blobs.first?.blob == SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 5))
    }

    @Test("A certificate beside the key is read alongside the key itself")
    func readsTheCertificateSidecar() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_ed25519")
        try Self.write(
            SSHPublicKeyFixture.line(type: Self.ed25519, seed: 6) + "\n",
            to: directory.appendingPathComponent("id_ed25519.pub")
        )
        try Self.write(
            SSHPublicKeyFixture.line(type: Self.certificate, seed: 7) + "\n",
            to: directory.appendingPathComponent("id_ed25519-cert.pub")
        )

        let blobs = SSHPublicKeyFile.blobs(atIdentityPath: key.path)

        #expect(blobs.count == 2)
        #expect(blobs.contains { $0.isCertificate })
        #expect(blobs.contains { !$0.isCertificate })
    }

    @Test("The same key reached by two candidate paths is returned once")
    func deduplicatesIdenticalBlobs() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = SSHPublicKeyFixture.line(type: Self.ed25519, seed: 8) + "\n"
        let key = directory.appendingPathComponent("id_ed25519")
        try Self.write(line, to: key)
        try Self.write(line, to: directory.appendingPathComponent("id_ed25519.pub"))

        #expect(SSHPublicKeyFile.blobs(atIdentityPath: key.path).count == 1)
    }

    @Test("An identity file that resolves to nothing yields no keys")
    func missingFileYieldsNothing() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SSHPublicKeyFile.blobs(atIdentityPath: directory.appendingPathComponent("absent").path).isEmpty)
        #expect(SSHPublicKeyFile.blobs(atIdentityPath: "").isEmpty)
    }

    @Test("A tilde in the identity path is expanded")
    func expandsTilde() throws {
        let name = "tp-pubkey-\(UUID().uuidString).pub"
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
        try Self.write(SSHPublicKeyFixture.line(type: Self.ed25519, seed: 9) + "\n", to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let blobs = SSHPublicKeyFile.blobs(atIdentityPath: "~/\(name)")

        #expect(blobs.first?.blob == SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 9))
    }
}
