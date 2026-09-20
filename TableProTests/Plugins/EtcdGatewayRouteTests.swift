//
//  EtcdGatewayRouteTests.swift
//  TableProTests
//
//  Which gateway prefix an etcd server routes is a 404-or-not question. Measured: etcd 3.2
//  serves only /v3alpha, 3.3 only /v3beta, and 3.4 onward /v3.
//

import Foundation
import Testing

private func gatewayBody(_ text: String) -> Data {
    Data(text.utf8)
}

@Suite("EtcdGatewayRoute")
struct EtcdGatewayRouteTests {
    @Test("v3 is tried before the legacy prefixes")
    func prefixOrder() {
        #expect(EtcdGatewayRoute.candidatePrefixes == ["v3", "v3beta", "v3alpha"])
    }

    @Test("Only 404 means the prefix is not routed")
    func notFoundIsTheOnlyRejection() {
        #expect(
            EtcdGatewayRoute.classify(httpStatus: 404, body: gatewayBody("404 page not found")) == .notRouted
        )
        #expect(
            EtcdGatewayRoute.classify(httpStatus: 404, body: gatewayBody(#"{"code":5}"#)) == .notRouted
        )
    }

    @Test("An auth fault proves the prefix is routed")
    func authFaultIsRouted() {
        let fault = gatewayBody(#"{"code":3, "message":"etcdserver: user name is empty"}"#)
        #expect(EtcdGatewayRoute.classify(httpStatus: 400, body: fault) == .routed)
        #expect(EtcdGatewayRoute.classify(httpStatus: 401, body: fault) == .routed)
        #expect(EtcdGatewayRoute.classify(httpStatus: 403, body: fault) == .routed)
    }

    @Test("A successful answer is routed")
    func successIsRouted() {
        #expect(
            EtcdGatewayRoute.classify(httpStatus: 200, body: gatewayBody(#"{"header":{}}"#)) == .routed
        )
    }

    @Test("A non-etcd answer is not accepted as a gateway")
    func nonEtcdAnswers() {
        #expect(EtcdGatewayRoute.classify(httpStatus: 200, body: gatewayBody("<html></html>")) == .notEtcd)
        #expect(EtcdGatewayRoute.classify(httpStatus: 200, body: Data()) == .notEtcd)
        #expect(EtcdGatewayRoute.classify(httpStatus: 200, body: gatewayBody("[1,2,3]")) == .notEtcd)
    }
}
