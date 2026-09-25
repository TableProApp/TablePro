//
//  EtcdServerFaultTests.swift
//  TableProTests
//
//  etcd's gateway reports every failure as a gRPC code plus a message, and grpc-gateway maps
//  two distinct codes onto HTTP 400. These pin the classification to the code, measured against
//  etcd 3.5.17 and 3.6.1.
//

import Foundation
import Testing

private func etcdBody(_ json: String) -> Data {
    Data(json.utf8)
}

struct EtcdServerFaultClassificationTests {
    @Test("etcd 3.6 reports a missing token as InvalidArgument, not Unauthorized")
    func missingTokenOnEtcd36() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(#"{"code":3, "message":"etcdserver: user name is empty"}"#)
        )
        #expect(fault.grpcCode == 3)
        #expect(fault.kind == .credentialsRequired)
    }

    @Test("etcd 3.5 carries the same fault with an extra error key")
    func missingTokenOnEtcd35() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(
                #"{"error":"etcdserver: user name is empty","code":3,"message":"etcdserver: user name is empty"}"#
            )
        )
        #expect(fault.kind == .credentialsRequired)
        #expect(fault.message == "etcdserver: user name is empty")
    }

    @Test("A wrong password shares the gRPC code of a missing token")
    func wrongPassword() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(
                #"{"code":3, "message":"etcdserver: authentication failed, invalid user ID or password"}"#
            )
        )
        #expect(fault.kind == .credentialsRejected)
    }

    @Test("A stale auth store revision is its own kind")
    func staleAuthRevision() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(#"{"code":3, "message":"etcdserver: revision of auth store is old"}"#)
        )
        #expect(fault.kind == .authRevisionStale)
    }

    @Test("Authentication disabled on the server is recognised")
    func authNotEnabled() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(#"{"code":9, "message":"etcdserver: authentication is not enabled"}"#)
        )
        #expect(fault.kind == .authNotEnabled)
    }

    @Test("Another FailedPrecondition stays unclassified")
    func roleNotFound() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(#"{"code":9, "message":"etcdserver: role name not found"}"#)
        )
        #expect(fault.kind == .unclassified)
    }

    @Test("Permission denied proves the session is live")
    func permissionDenied() {
        let fault = EtcdServerFault.decode(
            httpStatus: 403,
            body: etcdBody(#"{"code":7, "message":"etcdserver: permission denied"}"#)
        )
        #expect(fault.kind == .permissionDenied)
        #expect(fault.provesLiveSession)
    }

    @Test("A rejected token is its own kind")
    func invalidToken() {
        let fault = EtcdServerFault.decode(
            httpStatus: 401,
            body: etcdBody(#"{"code":16, "message":"etcdserver: invalid auth token"}"#)
        )
        #expect(fault.kind == .tokenRejected)
        #expect(!fault.provesLiveSession)
    }

    @Test("The HTTP status never decides the classification")
    func statusIsNotConsulted() {
        let payload = etcdBody(#"{"code":16, "message":"etcdserver: invalid auth token"}"#)
        #expect(EtcdServerFault.decode(httpStatus: 401, body: payload).kind == .tokenRejected)
        #expect(EtcdServerFault.decode(httpStatus: 500, body: payload).kind == .tokenRejected)
        #expect(EtcdServerFault.decode(httpStatus: 200, body: payload).kind == .tokenRejected)
    }
}

struct EtcdServerFaultDecodingTests {
    @Test("A plain text body survives as the message")
    func plainTextBody() {
        let fault = EtcdServerFault.decode(httpStatus: 404, body: etcdBody("404 page not found\n"))
        #expect(fault.grpcCode == nil)
        #expect(fault.message == "404 page not found")
        #expect(fault.kind == .unclassified)
    }

    @Test("An empty body falls back to the HTTP status")
    func emptyBody() {
        let fault = EtcdServerFault.decode(httpStatus: 502, body: Data())
        #expect(fault.grpcCode == nil)
        #expect(fault.message.contains("502"))
    }

    @Test("A long plain text body is capped")
    func longBody() {
        let fault = EtcdServerFault.decode(
            httpStatus: 500,
            body: etcdBody(String(repeating: "x", count: 4_000))
        )
        #expect(fault.message.count == 512)
    }

    @Test("A missing token asks for credentials instead of quoting etcd")
    func credentialsRequiredMessage() {
        let fault = EtcdServerFault.decode(
            httpStatus: 400,
            body: etcdBody(#"{"code":3, "message":"etcdserver: user name is empty"}"#)
        )
        #expect(fault.localizedDescription.contains("username"))
        #expect(!fault.localizedDescription.contains("user name is empty"))
    }

    @Test("Permission denied reads as etcd wrote it")
    func permissionDeniedMessage() {
        let fault = EtcdServerFault.decode(
            httpStatus: 403,
            body: etcdBody(#"{"code":7, "message":"etcdserver: permission denied"}"#)
        )
        #expect(fault.localizedDescription == "etcdserver: permission denied")
    }
}
