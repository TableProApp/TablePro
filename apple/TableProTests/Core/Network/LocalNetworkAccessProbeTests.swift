//
//  LocalNetworkAccessProbeTests.swift
//  TableProTests
//
//  The probe's answer comes from what Network framework reports on a UDP connection. Measured on
//  macOS 27: a satisfied path to a LAN, public or loopback address goes ready in under 10 ms and
//  carries `unsatisfiedReason == .notAvailable`; an unknown name waits with NoSuchRecord.
//

import dnssd
import Foundation
import Network
@testable import TablePro
import Testing

struct LocalNetworkAccessProbeTests {
    @Test("A path the Local Network permission refused is a denial")
    func refusedPathIsDenied() {
        #expect(LocalNetworkProbeSignal.path(status: .unsatisfied, reason: .localNetworkDenied).verdict == .denied)
    }

    @Test("A path's reason counts only when the path is unsatisfied")
    func satisfiedPathKeepsListening() {
        #expect(LocalNetworkProbeSignal.path(status: .satisfied, reason: .notAvailable).verdict == nil)
        #expect(LocalNetworkProbeSignal.path(status: .satisfied, reason: .localNetworkDenied).verdict == nil)
        #expect(LocalNetworkProbeSignal.path(status: .unsatisfied, reason: .notAvailable).verdict == nil)
    }

    @Test("A .local name refused during resolution is a denial")
    func mdnsPolicyRefusalIsDenied() {
        let error = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))

        #expect(LocalNetworkProbeSignal.waiting(error, status: .satisfied, reason: .notAvailable).verdict == .denied)
    }

    @Test("Waiting on a refused path is a denial")
    func waitingOnRefusedPathIsDenied() {
        let signal = LocalNetworkProbeSignal.waiting(.posix(.EHOSTUNREACH), status: .unsatisfied, reason: .localNetworkDenied)

        #expect(signal.verdict == .denied)
    }

    @Test("A name that does not resolve says nothing about the permission")
    func unresolvedNameIsUndetermined() {
        let error = NWError.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))

        #expect(LocalNetworkProbeSignal.waiting(error, status: .satisfied, reason: .notAvailable).verdict == .undetermined)
        #expect(LocalNetworkProbeSignal.waiting(error, status: nil, reason: nil).verdict == .undetermined)
    }

    @Test("A ready connection is granted, and one that ended or stayed silent is undetermined")
    func readyEndedAndSilent() {
        #expect(LocalNetworkProbeSignal.ready.verdict == .granted)
        #expect(LocalNetworkProbeSignal.ended.verdict == .undetermined)
        #expect(LocalNetworkProbeSignal.deadline.verdict == .undetermined)
    }

    @Test("Loopback never needs the permission")
    func loopbackProbeIsGranted() async {
        #expect(await NetworkFrameworkLocalNetworkProbe().access(to: "127.0.0.1") == .granted)
    }
}
