//
//  PluginSignatureValidationFlagsTests.swift
//  TableProTests
//

import Security
@testable import TablePro
import Testing

struct PluginSignatureValidationFlagsTests {
    @Test("Nested Mach-O inside a plugin bundle is verified")
    func flagsCheckNestedCode() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSCheckNestedCode != 0)
    }

    @Test("Resource envelope anomalies are rejected rather than permitted")
    func flagsValidateStrictly() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSStrictValidate != 0)
    }

    @Test("A symbolic link pointing outside the bundle is rejected")
    func flagsRestrictSymlinks() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSRestrictSymlinks != 0)
    }

    @Test("Every architecture is still checked")
    func flagsCheckAllArchitectures() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSCheckAllArchitectures != 0)
    }
}
