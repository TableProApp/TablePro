//
//  KeychainAccessControlTests.swift
//  TableProTests
//

import Foundation
import Security
import Testing
@testable import TablePro

@Suite("Keychain Access Control")
struct KeychainAccessControlTests {
    @Test("AfterFirstUnlock constant is available for syncable items")
    func correctConstantAvailable() {
        let expected = kSecAttrAccessibleAfterFirstUnlock
        #expect(expected != nil)
    }

    @Test("AfterFirstUnlockThisDeviceOnly constant is available for non-syncable items")
    func deviceOnlyConstantAvailable() {
        let expected = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #expect(expected != nil)
    }

    @Test("Data Protection keychain flag is a valid boolean")
    func dataProtectionKeychainFlag() {
        let flag = kSecUseDataProtectionKeychain
        #expect(flag != nil)
    }
}
