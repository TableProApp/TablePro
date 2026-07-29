//
//  SSHAuthMethodTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SSHAuthMethod form contract")
struct SSHAuthMethodTests {
    @Test("None is the only method without two-factor authentication")
    func noneHidesTwoFactor() {
        #expect(SSHAuthMethod.none.supportsTwoFactorAuthentication == false)

        for method in SSHAuthMethod.allCases where method != .none {
            #expect(method.supportsTwoFactorAuthentication, "\(method.rawValue) should support two-factor")
        }
    }
}
