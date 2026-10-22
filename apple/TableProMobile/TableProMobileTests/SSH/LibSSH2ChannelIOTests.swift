//
//  LibSSH2ChannelIOTests.swift
//  TableProMobileTests
//
//  Measured: a stopped sshd makes libssh2_channel_read return -43 at once; read as a channel close, the tunnel lived on until the keep-alive failed, about 37 s later.
//

import TableProSSHTransport
import Testing

@testable import TableProMobile

struct LibSSH2ChannelIOTests {
    // OUTOFORDER, FAILURE, REQUEST_DENIED, UNKNOWN, WINDOW_EXCEEDED, PACKET_EXCEEDED, CLOSED, EOF_SENT, WINDOW_FULL
    static let channelScopedCodes = [-20, -21, -22, -23, -24, -25, -26, -27, -47]

    // SOCKET_RECV, SOCKET_SEND, SOCKET_DISCONNECT, DECRYPT, OUT_OF_BOUNDARY, KEX_FAILURE, KEY_EXCHANGE_FAILURE, ALLOC, PROTO, SOCKET_NONE, INVALID_MAC
    static let transportCodes = [-43, -7, -13, -12, -41, -5, -8, -6, -14, -1, -4]

    @Test("A channel-scoped read error closes only the channel", arguments: LibSSH2ChannelIOTests.channelScopedCodes)
    func channelScopedReadErrorCloses(code: Int) {
        #expect(LibSSH2ChannelIO.readResult(code) == .closed)
    }

    @Test("A channel-scoped write error closes only the channel", arguments: LibSSH2ChannelIOTests.channelScopedCodes)
    func channelScopedWriteErrorCloses(code: Int) {
        #expect(LibSSH2ChannelIO.writeResult(code) == .closed)
    }

    @Test("A transport read error fails the transport", arguments: LibSSH2ChannelIOTests.transportCodes)
    func transportReadErrorFails(code: Int) {
        #expect(LibSSH2ChannelIO.readResult(code) == .transportFailed)
    }

    @Test("A transport write error fails the transport", arguments: LibSSH2ChannelIOTests.transportCodes)
    func transportWriteErrorFails(code: Int) {
        #expect(LibSSH2ChannelIO.writeResult(code) == .transportFailed)
    }

    @Test("EAGAIN would block on read and write")
    func eagainWouldBlock() {
        #expect(LibSSH2ChannelIO.readResult(-37) == .wouldBlock)
        #expect(LibSSH2ChannelIO.writeResult(-37) == .wouldBlock)
    }

    @Test("A positive count is the bytes moved")
    func positiveCountIsBytes() {
        #expect(LibSSH2ChannelIO.readResult(512) == .bytes(512))
        #expect(LibSSH2ChannelIO.writeResult(1) == .bytes(1))
    }

    @Test("A zero-byte read is a closed channel")
    func zeroReadIsClosed() {
        #expect(LibSSH2ChannelIO.readResult(0) == .closed)
    }
}
