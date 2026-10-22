import Foundation

// The name-lists of the server's first SSH_MSG_KEXINIT (RFC 4253, 7.1). It travels before any keys
// exist, so it reads in the clear from the bytes the handshake received.
public struct SSHServerProposal: Equatable, Sendable {
    public let keyExchange: [String]
    public let hostKeys: [String]
    public let ciphersClientToServer: [String]
    public let ciphersServerToClient: [String]
    public let macsClientToServer: [String]
    public let macsServerToClient: [String]

    init(
        keyExchange: [String],
        hostKeys: [String],
        ciphersClientToServer: [String],
        ciphersServerToClient: [String],
        macsClientToServer: [String],
        macsServerToClient: [String]
    ) {
        self.keyExchange = keyExchange
        self.hostKeys = hostKeys
        self.ciphersClientToServer = ciphersClientToServer
        self.ciphersServerToClient = ciphersServerToClient
        self.macsClientToServer = macsClientToServer
        self.macsServerToClient = macsServerToClient
    }

    public init?(received: [UInt8]) {
        guard let start = Self.packetsStart(in: received) else { return nil }
        var stream = SSHWireReader(Array(received[start...]))

        // Before the first NEWKEYS a packet has no MAC. A server may send IGNORE or DEBUG first.
        while let length = stream.uint32(), let padding = stream.byte(), length > Int(padding) {
            guard let payload = stream.bytes(length - Int(padding) - 1), stream.bytes(Int(padding)) != nil else {
                return nil
            }
            guard payload.first == Self.kexInit else { continue }

            var reader = SSHWireReader(Array(payload.dropFirst(1 + Self.cookieLength)))
            guard let keyExchange = reader.nameList(),
                  let hostKeys = reader.nameList(),
                  let ciphersClientToServer = reader.nameList(),
                  let ciphersServerToClient = reader.nameList(),
                  let macsClientToServer = reader.nameList(),
                  let macsServerToClient = reader.nameList()
            else { return nil }
            self.init(
                keyExchange: keyExchange,
                hostKeys: hostKeys,
                ciphersClientToServer: ciphersClientToServer,
                ciphersServerToClient: ciphersServerToClient,
                macsClientToServer: macsClientToServer,
                macsServerToClient: macsServerToClient
            )
            return
        }
        return nil
    }

    private static let kexInit: UInt8 = 20
    private static let cookieLength = 16

    // RFC 4253, 4.2: the server may send other lines before its identification line.
    private static func packetsStart(in received: [UInt8]) -> Int? {
        let identification = Array("SSH-".utf8)
        var lineStart = received.startIndex
        while let newline = received[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            if received[lineStart..<newline].starts(with: identification) {
                return newline + 1
            }
            lineStart = newline + 1
        }
        return nil
    }
}
