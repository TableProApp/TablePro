//
//  MSSQLSSLMappingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MSSQLSSLMapping.freetdsEncryptionFlag")
struct MSSQLSSLMappingTests {
    @Test("disabled maps to off")
    func disabled() {
        #expect(MSSQLSSLMapping.freetdsEncryptionFlag(for: .disabled) == "off")
    }

    @Test("preferred maps to request")
    func preferred() {
        #expect(MSSQLSSLMapping.freetdsEncryptionFlag(for: .preferred) == "request")
    }

    @Test("required maps to require")
    func required() {
        #expect(MSSQLSSLMapping.freetdsEncryptionFlag(for: .required) == "require")
    }

    @Test("verifyCa maps to require")
    func verifyCa() {
        #expect(MSSQLSSLMapping.freetdsEncryptionFlag(for: .verifyCa) == "require")
    }

    @Test("verifyIdentity maps to require")
    func verifyIdentity() {
        #expect(MSSQLSSLMapping.freetdsEncryptionFlag(for: .verifyIdentity) == "require")
    }
}
