import Darwin
import Foundation

public final class TeradataConnection {
    private let config: TeradataConnectionConfig
    private var socket: (any TeradataTransport)?
    private var sessionNumber: UInt32 = 0
    private var aesKey: [UInt8] = []
    private var charsetCode: UInt8 = 0xBF
    private var serverIP = "0.0.0.0"
    private var messageCounter: UInt64 = 0
    private var requestCounter: UInt64 = 0
    private var gssSequence: UInt64 = 0
    private var confidentialityBypassed = false

    public init(config: TeradataConnectionConfig) {
        self.config = config
    }

    public var isConnected: Bool { socket != nil }

    public func connect() throws {
        try validateLogMech()
        let socket = try makeTransport()
        self.socket = socket
        serverIP = Self.resolveAddress(config.host) ?? config.host

        try runConfig()
        let serverToken = try runAssign()
        let params = try Td2Token.parseServerParams(serverToken)
        try runKeyExchange(params)
        try runConnect()

        if let database = config.database, !database.isEmpty {
            _ = try execute(TeradataSchemaQueries.setDatabase(database))
        }
    }

    public func execute(_ sql: String) throws -> TeradataResultSet {
        guard socket != nil else { throw TeradataWireError.connectionFailed("not connected") }
        let requestNumber = nextRequest()
        let body = TeradataMessages.optionsParcel(returnStatementInfo: false).encoded()
            + TeradataMessages.requestParcel(sql: sql).encoded()
            + TeradataMessages.responseParcel().encoded()
        try sendEncrypted(kind: .start, body: body, requestNumber: requestNumber)

        var parcels: [Parcel] = []
        var responseComplete = false
        while !responseComplete {
            let batch = try readReply()
            parcels.append(contentsOf: batch)
            if Self.responseIsComplete(batch) {
                responseComplete = true
            } else {
                try sendContinue(requestNumber: requestNumber)
            }
        }
        return try TeradataResultParser.parse(parcels)
    }

    public func disconnect() {
        guard let socket else { return }
        if sessionNumber != 0 {
            let message = LanMessage(
                kind: .logoff, body: TeradataMessages.logoffParcel().encoded(),
                sessionNumber: sessionNumber, byteVar: 0,
                authentication: TeradataMessages.authBytes(nextMessage()), hostCharSet: charsetCode)
            try? socket.send(message.encoded())
        }
        socket.close()
        self.socket = nil
    }

    public func cancel() {
        socket?.cancel()
    }

    static func responseIsComplete(_ parcels: [Parcel]) -> Bool {
        let terminators: Set<UInt16> = [
            ParcelFlavor.endRequest.rawValue,
            ParcelFlavor.failure.rawValue,
            ParcelFlavor.error.rawValue,
            ParcelFlavor.statementError.rawValue,
        ]
        return parcels.contains { terminators.contains($0.flavor) }
    }

    private func makeTransport() throws -> any TeradataTransport {
        guard config.tls.enabled else {
            return try TeradataSocket(
                host: config.host, port: config.port, timeoutSeconds: config.connectTimeoutSeconds)
        }
        do {
            let transport = try TeradataTLSTransport(
                host: config.host, options: config.tls,
                timeoutSeconds: config.connectTimeoutSeconds)
            confidentialityBypassed = true
            return transport
        } catch {
            guard config.tls.allowPlaintextFallback else { throw error }
            return try TeradataSocket(
                host: config.host, port: config.port, timeoutSeconds: config.connectTimeoutSeconds)
        }
    }

    private func validateLogMech() throws {
        switch config.logMech {
        case .td2, .tdnego:
            return
        case .ldap, .krb5, .jwt:
            throw TeradataWireError.unsupported(
                "logon mechanism \(config.logMech.rawValue); only TD2 and TDNEGO are supported")
        }
    }

    private func runConfig() throws {
        let message = LanMessage(
            kind: .config, body: TeradataMessages.clientConfigParcel().encoded(),
            byteVar: 7, authentication: TeradataMessages.authBytes(nextMessage()),
            hostCharSet: LanMessage.charsetUnnegotiated)
        try socket?.send(message.encoded())
        let parcels = try readClearReply()
        try throwIfError(parcels)
        if let config = parcels.first(where: { $0.flavor == ParcelFlavor.configRsp.rawValue }) {
            charsetCode = TeradataMessages.charsetCode(fromConfigResponse: config.body, name: "UTF8")
                ?? TeradataMessages.charsetCode(fromConfigResponse: config.body, name: "ASCII")
                ?? 0xBF
        }
    }

    private func runAssign() throws -> [UInt8] {
        let sso = TeradataMessages.ssoRequestParcel(method: 0, trip: 0, token: Td2Token.clientInitToken)
        let assign = TeradataMessages.assignParcel(username: config.username)
        let message = LanMessage(
            kind: .assign, body: sso.encoded() + assign.encoded(),
            sessionNumber: 0, byteVar: 7,
            authentication: TeradataMessages.authBytes(nextMessage()), hostCharSet: charsetCode)
        let reply = try readFramed(after: message)
        sessionNumber = reply.sessionNumber
        let parcels = try Parcel.decodeAll(reply.body)
        try throwIfError(parcels)
        guard let sso = parcels.first(where: { $0.flavor == 134 }), sso.body.count >= 6 else {
            throw TeradataWireError.malformed("assign reply missing SSOResponse")
        }
        let length = Int(sso.body[4]) << 8 | Int(sso.body[5])
        return Array(sso.body[6..<min(6 + length, sso.body.count)])
    }

    private func runKeyExchange(_ params: Td2Token.ServerParams) throws {
        let dh = DiffieHellman(primeBytes: params.prime, generatorBytes: params.generator)
        let master = dh.masterKeyNormalizeTemp(peerPublicKeyBytes: params.serverPublicKey)
        let keyLength = Td2Token.qopKeyLengthBytes(params.qopDer) ?? 32
        aesKey = Array(master.prefix(keyLength))
        let responseToken = Td2Token.buildResponseToken(clientPublicKey: dh.publicKeyBytes())
        let sso = TeradataMessages.ssoRequestParcel(method: 0, trip: 2, token: responseToken)
        let message = LanMessage(
            kind: .sso, body: sso.encoded(),
            sessionNumber: sessionNumber, byteVar: 7,
            authentication: TeradataMessages.authBytes(nextMessage()), hostCharSet: charsetCode)
        try socket?.send(message.encoded())
        let parcels = try readClearReply()
        try throwIfError(parcels)
    }

    private func runConnect() throws {
        let logon = TeradataMessages.logonParcel(
            username: config.username, password: config.password, account: config.account)
        let sessionOptions = TeradataMessages.sessionOptionsParcel(
            semantics: config.transactionMode.semanticsByte, essEnabled: true)
        let connect = TeradataMessages.connectParcel(partition: "DBC/SQL")
        let logonData = TeradataMessages.logonDataParcel(
            host: config.host, port: config.port, username: config.username)
        let attributes = TeradataMessages.clientAttributesParcel(
            username: config.username, session: sessionNumber, charset: charsetCode,
            serverIP: serverIP, logMech: config.logMech.rawValue,
            transactionMode: config.transactionMode.rawValue, sslMode: config.tls.modeLabel,
            encryptData: !confidentialityBypassed, database: config.database)
        let body = logon.encoded() + sessionOptions.encoded() + connect.encoded()
            + logonData.encoded() + attributes.encoded()
        try sendEncrypted(kind: .connect, body: body, requestNumber: 0)
        let parcels = try readReply()
        try throwIfError(parcels)
        let success = parcels.contains { $0.flavor == ParcelFlavor.success.rawValue }
            || parcels.contains { $0.flavor == ParcelFlavor.statementStatus.rawValue }
        guard success else { throw TeradataWireError.server(code: 0, message: "logon rejected") }
    }

    private func sendEncrypted(kind: MessageKind, body: [UInt8], requestNumber: UInt32) throws {
        let message = LanMessage(
            kind: kind, body: body, sessionNumber: sessionNumber, requestNumber: requestNumber,
            byteVar: 0, authentication: TeradataMessages.authBytes(nextMessage()),
            hostCharSet: charsetCode)
        if confidentialityBypassed {
            try socket?.send(message.encoded())
            return
        }
        let wrapped = try Td2Wrap.encryptMessage(
            message.encoded(), key: aesKey, sequenceNumber: nextGssSequence())
        try socket?.send(wrapped)
    }

    private func sendContinue(requestNumber: UInt32) throws {
        try sendEncrypted(
            kind: .cont, body: TeradataMessages.responseParcel().encoded(), requestNumber: requestNumber)
    }

    private func readReply() throws -> [Parcel] {
        guard let socket else { throw TeradataWireError.connectionFailed("not connected") }
        let header = try socket.receive(LanMessage.headerLength)
        let bodyLength = LanMessage.bodyLength(fromHeader: header)
        let rest = try socket.receive(bodyLength)
        if header[1] & LanMessage.encryptedBodyFlag != 0 {
            let der = Array((header + rest)[24...])
            let plaintext = try Td2Wrap.unwrap(der: der, key: aesKey)
            guard plaintext.count >= 28 else {
                throw TeradataWireError.truncated("encrypted reply body \(plaintext.count) < 28")
            }
            return try Parcel.decodeAll(Array(plaintext[28...]))
        }
        return try Parcel.decodeAll(rest)
    }

    private func readClearReply() throws -> [Parcel] {
        guard let socket else { throw TeradataWireError.connectionFailed("not connected") }
        let header = try socket.receive(LanMessage.headerLength)
        let rest = try socket.receive(LanMessage.bodyLength(fromHeader: header))
        return try Parcel.decodeAll(rest)
    }

    private func readFramed(after message: LanMessage) throws -> LanMessage {
        guard let socket else { throw TeradataWireError.connectionFailed("not connected") }
        try socket.send(message.encoded())
        let header = try socket.receive(LanMessage.headerLength)
        let rest = try socket.receive(LanMessage.bodyLength(fromHeader: header))
        return LanMessage.decode(header: header, body: rest)
    }

    private func throwIfError(_ parcels: [Parcel]) throws {
        for parcel in parcels where parcel.flavor == ParcelFlavor.failure.rawValue
            || parcel.flavor == ParcelFlavor.error.rawValue {
            let (code, message) = TeradataResultParser.errorDetail(parcel)
            throw TeradataWireError.server(code: code, message: message)
        }
    }

    private func nextMessage() -> UInt64 {
        messageCounter += 1
        return messageCounter
    }

    private func nextRequest() -> UInt32 {
        requestCounter += 1
        return UInt32(truncatingIfNeeded: requestCounter)
    }

    private func nextGssSequence() -> UInt64 {
        gssSequence += 1
        return gssSequence
    }

    private static func resolveAddress(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let addr = result?.pointee.ai_addr else {
            return nil
        }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let sockaddrIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var inAddr = sockaddrIn.sin_addr
        guard inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
