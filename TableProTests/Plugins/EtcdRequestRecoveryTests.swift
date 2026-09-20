//
//  EtcdRequestRecoveryTests.swift
//  TableProTests
//
//  Mirrors clientv3's shouldRefreshToken: refresh on an invalid token, on a stale auth store
//  revision, and on a missing token when credentials exist. Never on permission denied.
//

import Foundation
import Testing

private func recoveryFault(code: Int, message: String) -> EtcdServerFault {
    EtcdServerFault(grpcCode: code, message: message)
}

private let missingToken = recoveryFault(code: 3, message: "etcdserver: user name is empty")
private let wrongPassword = recoveryFault(
    code: 3,
    message: "etcdserver: authentication failed, invalid user ID or password"
)
private let staleRevision = recoveryFault(code: 3, message: "etcdserver: revision of auth store is old")
private let rejectedToken = recoveryFault(code: 16, message: "etcdserver: invalid auth token")
private let deniedPermission = recoveryFault(code: 7, message: "etcdserver: permission denied")
private let authOff = recoveryFault(code: 9, message: "etcdserver: authentication is not enabled")

@Suite("EtcdRequestRecovery")
struct EtcdRequestRecoveryTests {
    @Test("A rejected token is refreshed once")
    func rejectedTokenRefreshes() {
        #expect(
            EtcdRequestRecovery.action(for: rejectedToken, hasCredentials: true, isRetry: false)
                == .reauthenticateAndRetry
        )
    }

    @Test("A missing token is refreshed when credentials exist")
    func missingTokenRefreshes() {
        #expect(
            EtcdRequestRecovery.action(for: missingToken, hasCredentials: true, isRetry: false)
                == .reauthenticateAndRetry
        )
    }

    @Test("A stale auth store revision is refreshed")
    func staleRevisionRefreshes() {
        #expect(
            EtcdRequestRecovery.action(for: staleRevision, hasCredentials: true, isRetry: false)
                == .reauthenticateAndRetry
        )
    }

    @Test("Permission denied is never retried")
    func permissionDeniedSurfaces() {
        #expect(
            EtcdRequestRecovery.action(for: deniedPermission, hasCredentials: true, isRetry: false)
                == .surface
        )
    }

    @Test("A wrong password is never retried")
    func wrongPasswordSurfaces() {
        #expect(
            EtcdRequestRecovery.action(for: wrongPassword, hasCredentials: true, isRetry: false)
                == .surface
        )
    }

    @Test("Authentication being off is never retried")
    func authOffSurfaces() {
        #expect(
            EtcdRequestRecovery.action(for: authOff, hasCredentials: true, isRetry: false) == .surface
        )
    }

    @Test("A connection with no credentials cannot recover")
    func noCredentialsSurfaces() {
        #expect(
            EtcdRequestRecovery.action(for: missingToken, hasCredentials: false, isRetry: false)
                == .surface
        )
        #expect(
            EtcdRequestRecovery.action(for: rejectedToken, hasCredentials: false, isRetry: false)
                == .surface
        )
    }

    @Test("A retry never refreshes again")
    func retryDoesNotLoop() {
        #expect(
            EtcdRequestRecovery.action(for: rejectedToken, hasCredentials: true, isRetry: true) == .surface
        )
        #expect(
            EtcdRequestRecovery.action(for: missingToken, hasCredentials: true, isRetry: true) == .surface
        )
    }

    @Test("An unrecognised fault is surfaced")
    func unclassifiedSurfaces() {
        let fault = recoveryFault(code: 5, message: "etcdserver: key is not provided")
        #expect(
            EtcdRequestRecovery.action(for: fault, hasCredentials: true, isRetry: false) == .surface
        )
    }
}
