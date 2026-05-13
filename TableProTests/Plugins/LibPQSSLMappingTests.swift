//
//  LibPQSSLMappingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("LibPQSSLMapping.sslmode")
struct LibPQSSLMappingTests {
    @Test("disabled maps to disable")
    func disabled() {
        #expect(LibPQSSLMapping.sslmode(for: .disabled) == "disable")
    }

    @Test("preferred maps to prefer")
    func preferred() {
        #expect(LibPQSSLMapping.sslmode(for: .preferred) == "prefer")
    }

    @Test("required maps to require")
    func required() {
        #expect(LibPQSSLMapping.sslmode(for: .required) == "require")
    }

    @Test("verifyCa maps to verify-ca")
    func verifyCa() {
        #expect(LibPQSSLMapping.sslmode(for: .verifyCa) == "verify-ca")
    }

    @Test("verifyIdentity maps to verify-full")
    func verifyIdentity() {
        #expect(LibPQSSLMapping.sslmode(for: .verifyIdentity) == "verify-full")
    }
}
