//
//  ConnectionSignInRegistryTests.swift
//  TableProTests
//
//  Which failures the app offers to recover by signing in again. This used to be two inline
//  branches in the connection form with no coverage at all.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Connection sign-in providers")
struct ConnectionSignInRegistryTests {
    private let ssoFields = ["awsAuth": "sso", "awsProfileName": "engineering"]
    private let entraFields = [
        "mssqlAuthMethod": "entra",
        EntraField.clientId: "11111111-2222-3333-4444-555555555555"
    ]

    @Test("An expired SSO session on an SSO connection is offered a sign-in")
    func claimsExpiredSSOSession() {
        let provider = ConnectionSignInRegistry.provider(
            for: AWSSSOError.tokenExpired(profile: "engineering"),
            fields: ssoFields
        )
        #expect(provider?.kind == .awsSSO)
    }

    @Test("Both spellings of the AWS auth field select the SSO provider")
    func acceptsBothAWSAuthKeys() {
        let error = AWSSSOError.sessionUnauthorized(profile: "engineering")
        #expect(
            ConnectionSignInRegistry.provider(for: error, fields: ["awsAuth": "sso"])?.kind == .awsSSO
        )
        #expect(
            ConnectionSignInRegistry.provider(for: error, fields: ["awsAuthMethod": "sso"])?.kind == .awsSSO
        )
    }

    @Test("An expired SSO session on a connection that does not use SSO is not claimed")
    func ignoresSSOErrorWithoutSSOAuth() {
        let provider = ConnectionSignInRegistry.provider(
            for: AWSSSOError.tokenExpired(profile: "engineering"),
            fields: ["awsAuth": "accessKey"]
        )
        #expect(provider == nil)
    }

    @Test("The SSO prompt names the profile that expired")
    func namesTheExpiredProfile() {
        let provider = ConnectionSignInRegistry.provider(
            for: AWSSSOError.tokenExpired(profile: "engineering"),
            fields: ssoFields
        )
        #expect(provider?.message(ssoFields).contains("engineering") == true)
    }

    @Test("A missing profile name falls back to default")
    func fallsBackToDefaultProfile() {
        #expect(AWSSSOLoginService.profileName(from: [:]) == "default")
        #expect(AWSSSOLoginService.profileName(from: ["awsProfileName": ""]) == "default")
        #expect(AWSSSOLoginService.profileName(from: ["awsProfileName": "prod"]) == "prod")
    }

    @Test("Entra states an interactive sign-in can fix are claimed")
    func claimsRecoverableEntraStates() {
        for error in [
            EntraOAuthError.signInRequired,
            EntraOAuthError.interactionRequired,
            EntraOAuthError.refreshRejected
        ] {
            #expect(ConnectionSignInRegistry.provider(for: error, fields: entraFields)?.kind == .entraID)
        }
    }

    @Test("A misconfigured Entra connection is not offered a sign-in, because signing in cannot fix it")
    func ignoresUnrecoverableEntraStates() {
        #expect(ConnectionSignInRegistry.provider(for: EntraOAuthError.notConfigured, fields: entraFields) == nil)
        #expect(ConnectionSignInRegistry.provider(for: EntraOAuthError.accessDenied, fields: entraFields) == nil)
        #expect(
            ConnectionSignInRegistry.provider(
                for: EntraOAuthError.network("offline"), fields: entraFields
            ) == nil
        )
    }

    @Test("An ordinary connection failure is claimed by nobody")
    func ignoresUnrelatedErrors() {
        struct Boom: Error {}
        #expect(ConnectionSignInRegistry.provider(for: Boom(), fields: ssoFields) == nil)
        #expect(ConnectionSignInRegistry.provider(for: Boom(), fields: entraFields) == nil)
        #expect(ConnectionSignInRegistry.provider(for: Boom(), fields: [:]) == nil)
    }

    @Test("Every provider carries the strings the prompt needs")
    func providersAreFullyDescribed() {
        #expect(ConnectionSignInRegistry.providers.count == ConnectionSignInKind.allCases.count)
        for provider in ConnectionSignInRegistry.providers {
            #expect(!provider.title.isEmpty)
            #expect(!provider.message([:]).isEmpty)
            #expect(!provider.signedInMessage.isEmpty)
            #expect(!provider.failureTitle.isEmpty)
        }
    }
}
