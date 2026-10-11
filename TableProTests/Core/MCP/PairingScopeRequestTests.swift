//
//  PairingScopeRequestTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct PairingScopeRequestTests {
    @Test("No scopes asks for Read Only and nothing else")
    func absentIsReadOnly() {
        for raw in [nil, "", " , "] as [String?] {
            let request = PairingScopeRequest.parse(raw)
            #expect(request.permissions == .readOnly)
            #expect(request.optionalGrants.isEmpty)
        }
    }

    @Test("A single level reads exactly as before")
    func singleLevel() {
        let cases: [(raw: String, expected: TokenPermissions)] = [
            ("readWrite", .readWrite),
            ("read_write", .readWrite),
            ("READ-WRITE", .readWrite),
            ("fullAccess", .fullAccess),
            ("full_access", .fullAccess),
            ("full-access", .fullAccess),
            ("full", .fullAccess),
            ("readOnly", .readOnly),
            ("whatever", .readOnly)
        ]
        for testCase in cases {
            let request = PairingScopeRequest.parse(testCase.raw)
            #expect(request.permissions == testCase.expected, "\(testCase.raw)")
            #expect(request.optionalGrants.isEmpty, "\(testCase.raw)")
        }
    }

    @Test("A level and the display scope, separated by a space or a comma")
    func levelWithDisplayScope() {
        for raw in ["readWrite connections:display", "readWrite,connections:display", "connections:display, readWrite"] {
            let request = PairingScopeRequest.parse(raw)
            #expect(request.permissions == .readWrite)
            #expect(request.optionalGrants == [.connectionsDisplay])
        }
    }

    @Test("The display scope alone asks for Read Only")
    func displayScopeAlone() {
        let request = PairingScopeRequest.parse("connections:display")
        #expect(request.permissions == .readOnly)
        #expect(request.optionalGrants == [.connectionsDisplay])
    }

    @Test("Unknown entries are skipped")
    func unknownEntriesAreSkipped() {
        let request = PairingScopeRequest.parse("fullAccess connections:everything bogus")
        #expect(request.permissions == .fullAccess)
        #expect(request.optionalGrants.isEmpty)
    }

    @Test("Several levels start the sheet at the lowest")
    func lowestLevelWins() {
        #expect(PairingScopeRequest.parse("fullAccess readOnly").permissions == .readOnly)
        #expect(PairingScopeRequest.parse("fullAccess,readWrite").permissions == .readWrite)
    }

    @Test("A tier scope named in the list is not an optional grant")
    func tierScopesAreNotOptionalGrants() {
        let request = PairingScopeRequest.parse("readOnly admin tools:write resources:read")
        #expect(request.permissions == .readOnly)
        #expect(request.optionalGrants.isEmpty)
    }

    @Test("With the setting off the display scope is refused, whatever the client and the sheet said")
    func settingOffRefusesTheScope() {
        let request = PairingScopeRequest.parse("readOnly connections:display")
        let granted = request.grantedOptionalScopes(
            approved: [.connectionsDisplay],
            allowsHiddenConnectionListing: false
        )
        #expect(granted.isEmpty)
    }

    @Test("With the setting on the scope needs the client to ask and the user to tick it")
    func settingOnNeedsRequestAndApproval() {
        let asked = PairingScopeRequest.parse("readOnly connections:display")
        let notAsked = PairingScopeRequest.parse("readOnly")

        #expect(asked.grantedOptionalScopes(approved: [], allowsHiddenConnectionListing: true).isEmpty)
        #expect(notAsked.grantedOptionalScopes(
            approved: [.connectionsDisplay],
            allowsHiddenConnectionListing: true
        ).isEmpty)
        #expect(asked.grantedOptionalScopes(
            approved: [.connectionsDisplay],
            allowsHiddenConnectionListing: true
        ) == [.connectionsDisplay])
    }

    @Test("A pairing request parses its own scopes")
    func requestExposesItsScopes() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:7391/callback"))
        let request = PairingRequest(
            clientName: "Launcher",
            challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            redirectURL: redirect,
            requestedScopes: "readWrite connections:display",
            requestedConnectionIds: nil
        )
        #expect(request.scopeRequest == PairingScopeRequest(
            permissions: .readWrite,
            optionalGrants: [.connectionsDisplay]
        ))
    }
}
