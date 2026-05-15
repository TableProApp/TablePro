//
//  HttpQueryTimeoutBoxTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("HttpQueryTimeoutBox")
struct HttpQueryTimeoutBoxTests {
    @Test("Default-initialized box exposes bootstrap policy")
    func defaultBoxIsBootstrap() {
        let box = HttpQueryTimeoutBox()
        #expect(box.current.serverTimeoutSeconds == HttpQueryTimeout.bootstrapSeconds)
        #expect(box.requestTimeoutInterval == TimeInterval(60 + 30))
    }

    @Test("set updates both current and requestTimeoutInterval")
    func setUpdatesBoth() {
        let box = HttpQueryTimeoutBox()
        box.set(serverTimeoutSeconds: 600)
        #expect(box.current.serverTimeoutSeconds == 600)
        #expect(box.requestTimeoutInterval == TimeInterval(630))
    }

    @Test("set with serverTimeoutSeconds = 0 falls back to resource ceiling")
    func setZeroUsesCeiling() {
        let box = HttpQueryTimeoutBox()
        box.set(serverTimeoutSeconds: 0)
        #expect(box.requestTimeoutInterval == TimeInterval(HttpQueryTimeout.resourceCeilingSeconds))
    }

    @Test("set with custom grace is honored")
    func setCustomGrace() {
        let box = HttpQueryTimeoutBox()
        box.set(serverTimeoutSeconds: 120, graceSeconds: 5)
        #expect(box.requestTimeoutInterval == TimeInterval(125))
    }

    @Test("Concurrent set and read does not crash")
    func concurrentAccess() async {
        let box = HttpQueryTimeoutBox()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask { box.set(serverTimeoutSeconds: 30 + index * 10) }
                group.addTask { _ = box.requestTimeoutInterval }
            }
        }
        #expect(box.requestTimeoutInterval >= TimeInterval(30))
    }

    @Test("Custom initial timeout is preserved until set is called")
    func customInitial() {
        let box = HttpQueryTimeoutBox(HttpQueryTimeout(serverTimeoutSeconds: 300, graceSeconds: 15))
        #expect(box.requestTimeoutInterval == TimeInterval(315))
        box.set(serverTimeoutSeconds: 600)
        #expect(box.requestTimeoutInterval == TimeInterval(630))
    }
}
