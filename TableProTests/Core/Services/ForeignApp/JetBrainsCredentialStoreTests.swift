//
//  JetBrainsCredentialStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("JetBrainsCredentialStore", .serialized)
struct JetBrainsCredentialStoreTests {
    private let configDir: URL

    init() throws {
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JetBrainsCredentialStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    @Test("service name uses em-dash separator")
    func serviceNameFormat() {
        let name = JetBrainsCredentialStore.serviceName(forDataSourceUUID: "abc-123")
        #expect(name == "IntelliJ Platform DB \u{2014} abc-123")
    }

    @Test("reads password from c.kdbx via c.pwd main key")
    func keePassFallback() throws {
        let uuid = "a1b2c3"
        let mainKey = KdbxTestFixture.randomBytes(64)
        let service = JetBrainsCredentialStore.serviceName(forDataSourceUUID: uuid)

        let kdbx = KdbxTestFixture.makeKdbx(mainKey: mainKey, title: service, userName: "u", password: "kdbx-secret")
        try kdbx.write(to: configDir.appendingPathComponent("c.kdbx"))
        try KdbxTestFixture.makeMainKeyFile(mainKey: mainKey)
            .write(to: configDir.appendingPathComponent("c.pwd"), atomically: true, encoding: .utf8)

        let store = JetBrainsCredentialStore(configDir: configDir)
        guard case .found(let password) = store.password(forDataSourceUUID: uuid) else {
            Issue.record("Expected password to be found in KDBX")
            return
        }
        #expect(password == "kdbx-secret")
    }

    @Test("missing files return notFound")
    func notFound() {
        let store = JetBrainsCredentialStore(configDir: configDir)
        guard case .notFound = store.password(forDataSourceUUID: "missing") else {
            Issue.record("Expected notFound when no keychain item and no c.kdbx")
            return
        }
    }
}
