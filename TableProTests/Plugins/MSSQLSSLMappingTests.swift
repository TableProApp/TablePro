//
//  MSSQLSSLMappingTests.swift
//  TableProTests
//

import Foundation
import TableProMSSQLCore
import TableProPluginKit
import Testing

@Suite("MSSQLSSLMapping.encryptionLevel")
struct MSSQLSSLMappingTests {
    @Test("disabled maps to request: off would send the login unencrypted, and a server that forces encryption drops it")
    func disabled() {
        #expect(MSSQLSSLMapping.encryptionLevel(for: .disabled) == .request)
    }

    @Test("preferred maps to request")
    func preferred() {
        #expect(MSSQLSSLMapping.encryptionLevel(for: .preferred) == .request)
    }

    @Test("required maps to require")
    func required() {
        #expect(MSSQLSSLMapping.encryptionLevel(for: .required) == .require)
    }

    @Test("verifyCa maps to require")
    func verifyCa() {
        #expect(MSSQLSSLMapping.encryptionLevel(for: .verifyCa) == .require)
    }

    @Test("verifyIdentity maps to require")
    func verifyIdentity() {
        #expect(MSSQLSSLMapping.encryptionLevel(for: .verifyIdentity) == .require)
    }
}
