//
//  RelayByteObserver.swift
//  TableProSSHTransport
//

import Foundation

/// Where a relay reports what crossed it. The relay counts bytes; what an app does with the
/// totals (a live readout, nothing at all) is the app's, so the accumulator stays there.
public protocol RelayByteObserver: Sendable {
    func recordReceived(_ count: Int)
    func recordSent(_ count: Int)
}
