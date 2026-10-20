//
//  SSHAuthMethodsTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHAuthMethodsTests {
    @Test("The server's list splits on commas in its order")
    func parsesTheList() {
        #expect(SSHAuthMethods.parse("publickey,password,keyboard-interactive") == [
            "publickey", "password", "keyboard-interactive",
        ])
    }

    @Test("No list, an empty one, or stray separators give no methods")
    func parsesNothing() {
        #expect(SSHAuthMethods.parse(nil).isEmpty)
        #expect(SSHAuthMethods.parse("").isEmpty)
        #expect(SSHAuthMethods.parse(",").isEmpty)
    }

    @Test("Blank entries and spaces are dropped")
    func dropsBlankEntries() {
        #expect(SSHAuthMethods.parse("publickey,, password ") == ["publickey", "password"])
    }

    @Test("A password accepted with a second step leaves only the next method")
    func passwordThenCode() {
        let remaining = SSHAuthMethods.remainingAfterPartialSuccess(
            of: "password",
            before: ["password"],
            after: ["keyboard-interactive"]
        )

        #expect(remaining == ["keyboard-interactive"])
    }

    @Test("A key accepted with a second step returns every method still on offer")
    func keyThenOthers() {
        let remaining = SSHAuthMethods.remainingAfterPartialSuccess(
            of: "publickey",
            before: ["publickey"],
            after: ["password", "keyboard-interactive"]
        )

        #expect(remaining == ["password", "keyboard-interactive"])
    }

    @Test("A rejected method stays on the list, so it is not partial success")
    func rejectedMethodStaysListed() {
        let remaining = SSHAuthMethods.remainingAfterPartialSuccess(
            of: "password",
            before: ["publickey", "password"],
            after: ["publickey", "password"]
        )

        #expect(remaining == nil)
    }

    @Test("An unreadable list after the failure, as after a disconnect, is not partial success")
    func emptyListAfter() {
        #expect(SSHAuthMethods.remainingAfterPartialSuccess(of: "password", before: ["password"], after: []) == nil)
    }

    @Test("A method the server never offered cannot have partly succeeded")
    func methodNotOfferedBefore() {
        let remaining = SSHAuthMethods.remainingAfterPartialSuccess(
            of: "keyboard-interactive",
            before: ["password"],
            after: ["publickey"]
        )

        #expect(remaining == nil)
    }
}
