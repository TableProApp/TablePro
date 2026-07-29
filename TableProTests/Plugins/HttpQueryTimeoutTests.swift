//
//  HttpQueryTimeoutTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("HttpQueryTimeout")
struct HttpQueryTimeoutTests {
    @Test("Default values match the documented bootstrap policy")
    func defaultsMatchBootstrap() {
        let timeout = HttpQueryTimeout()
        #expect(timeout.serverTimeoutSeconds == HttpQueryTimeout.bootstrapSeconds)
        #expect(timeout.graceSeconds == HttpQueryTimeout.defaultGraceSeconds)
        #expect(timeout.requestTimeoutInterval == TimeInterval(60 + 30))
    }

    @Test("Positive server timeout adds grace to request interval")
    func positiveServerTimeoutAddsGrace() {
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: 600, graceSeconds: 30)
        #expect(timeout.requestTimeoutInterval == TimeInterval(630))
    }

    @Test("Custom grace is honored")
    func customGrace() {
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: 120, graceSeconds: 5)
        #expect(timeout.requestTimeoutInterval == TimeInterval(125))
    }

    @Test("Zero server timeout falls back to the resource ceiling")
    func zeroServerTimeoutUsesCeiling() {
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: 0)
        #expect(timeout.requestTimeoutInterval == TimeInterval(HttpQueryTimeout.resourceCeilingSeconds))
    }

    @Test("Negative server timeout is treated as unlimited")
    func negativeServerTimeoutUsesCeiling() {
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: -1)
        #expect(timeout.requestTimeoutInterval == TimeInterval(HttpQueryTimeout.resourceCeilingSeconds))
    }

    @Test("Negative grace is clamped to zero")
    func negativeGraceClamped() {
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: 60, graceSeconds: -10)
        #expect(timeout.graceSeconds == 0)
        #expect(timeout.requestTimeoutInterval == TimeInterval(60))
    }

    @Test("Static session timeouts expose the documented ceilings")
    func staticSessionTimeouts() {
        #expect(HttpQueryTimeout.sessionBootstrapRequestTimeout == TimeInterval(60))
        #expect(HttpQueryTimeout.sessionResourceTimeout == TimeInterval(3_600))
    }

    @Test("URLRequest.timeoutInterval can be assigned from the helper")
    func appliesToUrlRequest() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        let timeout = HttpQueryTimeout(serverTimeoutSeconds: 300)
        request.timeoutInterval = timeout.requestTimeoutInterval
        #expect(request.timeoutInterval == TimeInterval(330))
    }
}
