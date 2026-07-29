//
//  KeychainStringResultValueTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import Testing

@Suite("KeychainStringResult.value")
struct KeychainStringResultValueTests {
    private let logger = Logger(subsystem: "com.TablePro.tests", category: "keychain")

    @Test("Found returns the value")
    func foundReturnsValue() {
        #expect(KeychainStringResult.found("secret").value(label: "password", logger: logger) == "secret")
    }

    @Test("Every non-found outcome returns nil")
    func nonFoundReturnsNil() {
        #expect(KeychainStringResult.notFound.value(label: "password", logger: logger) == nil)
        #expect(KeychainStringResult.locked.value(label: "password", logger: logger) == nil)
        #expect(KeychainStringResult.userCancelled.value(label: "password", logger: logger) == nil)
        #expect(KeychainStringResult.authFailed.value(label: "password", logger: logger) == nil)
        #expect(KeychainStringResult.error(-25_300).value(label: "password", logger: logger) == nil)
    }
}
