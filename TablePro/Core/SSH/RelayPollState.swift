//
//  RelayPollState.swift
//  TablePro
//

import Foundation

internal enum RelayFDState: Equatable {
    case idle
    case readable
    case drainThenStop
    case stop
}

internal func relayFDState(_ revents: Int16) -> RelayFDState {
    if revents & Int16(POLLERR | POLLNVAL) != 0 { return .stop }
    if revents & Int16(POLLHUP) != 0 { return .drainThenStop }
    if revents & Int16(POLLIN) != 0 { return .readable }
    return .idle
}
