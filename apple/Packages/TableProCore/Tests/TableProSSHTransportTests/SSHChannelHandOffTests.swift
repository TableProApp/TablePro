//
//  SSHChannelHandOffTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHChannelHandOffTests {
    private func fakeChannel() throws -> OpaquePointer {
        try #require(OpaquePointer(bitPattern: 0x1000))
    }

    @Test("The first taker inside the window gets the held channel, and only once")
    func firstTakerGetsFreshChannel() throws {
        let channel = try fakeChannel()
        let handOff = SSHChannelHandOff(window: .seconds(1))
        let openedAt = ContinuousClock.now
        #expect(handOff.hold(channel, openedAt: openedAt))

        #expect(handOff.take(at: openedAt.advanced(by: .milliseconds(200))) == .fresh(channel))
        #expect(handOff.take(at: openedAt.advanced(by: .milliseconds(300))) == .none)
    }

    @Test("A channel held past the window comes back stale, for the taker to free")
    func pastTheWindowIsStale() throws {
        let channel = try fakeChannel()
        let handOff = SSHChannelHandOff(window: .seconds(1))
        let openedAt = ContinuousClock.now
        #expect(handOff.hold(channel, openedAt: openedAt))

        #expect(handOff.take(at: openedAt.advanced(by: .seconds(1))) == .stale(channel))
    }

    @Test("Nothing held gives nothing")
    func emptySlot() {
        #expect(SSHChannelHandOff().take() == .none)
    }

    @Test("Closing gives back the held channel and refuses a channel that arrives later")
    func closeRefusesLateChannel() throws {
        let channel = try fakeChannel()
        let handOff = SSHChannelHandOff()
        #expect(handOff.hold(channel))

        #expect(handOff.close() == channel)
        #expect(!handOff.hold(channel))
        #expect(handOff.take() == .none)
        #expect(handOff.close() == nil)
    }
}
