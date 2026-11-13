import Darwin
import Foundation

// One queue drives it. Only `cancel()` comes from elsewhere, and what it reads and sends is under socketLock or wireLock.
public final class TeradataConnection: @unchecked Sendable {
    private let config: TeradataConnectionConfig
    private let socketLock = NSLock()
    private var _socket: (any TeradataTransport)?
    private var _hasLostConnection = false
    private var socket: (any TeradataTransport)? {
        get { socketLock.withLock { _socket } }
        set { socketLock.withLock { _socket = newValue } }
    }
    private var connectDeadline: TeradataConnectDeadline?
    private var sessionNumber: UInt32 = 0
    private var aesKey: [UInt8] = []
    private var charsetCode: UInt8 = 0xBF
    private var serverIP = "0.0.0.0"
    private var messageCounter: UInt64 = 0
    private var requestCounter: UInt64 = 0
    private var gssSequence: UInt64 = 0
    private var confidentialityBypassed = false

    // Orders every post-logon send with the counters it consumes, since Stop sends its abort from another thread.
    private let wireLock = NSLock()
    // Under socketLock, which is never held across I/O.
    private var _phase = RequestPhase.idle
    private var _stopRequested = false
    private var _operationActive = false
    // The request a stop is waiting on the server for, so the stop's deadline closes nothing that came after it.
    private var _stoppingRequest: UInt32?
    // Under socketLock: the semantics the session runs with, and what its requests have left open.
    private var _sessionMode: TeradataTransactionMode
    private var _sessionModeSource: TeradataSessionModeSource
    private var _transaction: TeradataTransactionTracker
    // Nil until a switch the connection made itself, and again once a request of the user's may have moved it.
    private var _defaultDatabase: String?

    // 3110: "The transaction was aborted by the user."
    public static let userAbortCode = 3_110
    private static let abortLockWait: TimeInterval = 0.25
    // A server or network that stops answering would otherwise hold a stop for the whole 20-second receive timeout.
    static let defaultStopGrace: TimeInterval = 5
    private let stopGrace: TimeInterval
    private let stopDeadlineQueue = DispatchQueue(label: "com.TablePro.teradata.stop-deadline")

    private enum RequestPhase: Equatable {
        case idle
        case connecting
        case awaitingResponse(UInt32)
        case fetching(UInt32)
    }

    private enum StopAction {
        case nothing
        case abort(UInt32)
        case endOutput(UInt32)
        case close
    }

    private enum Exchange {
        case answered
        case notSent
        case outputEnded
        // The consumer threw on a reply, and the request has ended on the wire.
        case refused(any Error)
    }

    public init(config: TeradataConnectionConfig) {
        self.config = config
        stopGrace = Self.defaultStopGrace
        let configured = Self.configuredMode(config.transactionMode)
        _sessionMode = configured.mode
        _sessionModeSource = configured.source
        _transaction = TeradataTransactionTracker(mode: configured.mode)
    }

    init(
        config: TeradataConnectionConfig,
        transport: any TeradataTransport,
        stopGrace: TimeInterval = TeradataConnection.defaultStopGrace
    ) {
        self.config = config
        self._socket = transport
        self.stopGrace = stopGrace
        confidentialityBypassed = true
        let configured = Self.configuredMode(config.transactionMode)
        _sessionMode = configured.mode
        _sessionModeSource = configured.source
        _transaction = TeradataTransactionTracker(mode: configured.mode)
    }

    private static func configuredMode(
        _ mode: TeradataTransactionMode
    ) -> (mode: TeradataTransactionMode, source: TeradataSessionModeSource) {
        mode == .default ? (.default, .unresolved) : (mode, .configured)
    }

    public var isConnected: Bool { socket != nil }

    // `.default` when the session could not say which semantics it runs with; it then gets Teradata's.
    public var sessionTransactionMode: TeradataTransactionMode { socketLock.withLock { _sessionMode } }

    public var sessionModeSource: TeradataSessionModeSource { socketLock.withLock { _sessionModeSource } }

    public var transactionState: TeradataTransactionState { socketLock.withLock { _transaction.state } }

    // Set when a request failed partway, so the session it ran on was given up rather than ended.
    public var hasLostConnection: Bool { socketLock.withLock { _hasLostConnection } }

    public func connect() throws {
        try validateLogMech()
        let deadline = TeradataConnectDeadline(milliseconds: config.connectTimeoutMilliseconds)
        connectDeadline = deadline
        let socket: any TeradataTransport
        do {
            socket = try makeTransport(deadline: deadline)
        } catch {
            connectDeadline = nil
            throw error
        }
        socketLock.withLock {
            _socket = socket
            _hasLostConnection = false
            _phase = .connecting
        }
        var established = false
        defer {
            if !established {
                socket.close()
                self.socket = nil
                connectDeadline = nil
            }
            socketLock.withLock { _phase = .idle }
        }
        serverIP = Self.resolveAddress(config.host) ?? config.host
        _ = try deadline.remainingMilliseconds()

        try runConfig()
        let serverToken = try runAssign()
        let params = try Td2Token.parseServerParams(serverToken)
        try runKeyExchange(params)
        try runConnect()
        try prepareSession()
        _ = try deadline.remainingMilliseconds()
        established = true
    }

    // The connect deadline holds through the driver's VERSION probe; only then does query I/O get the 20-second timeout.
    public func finishConnecting() throws {
        guard let socket, let connectDeadline else {
            throw TeradataWireError.connectionFailed("not connecting")
        }
        _ = try connectDeadline.remainingMilliseconds()
        socket.finishConnecting()
        self.connectDeadline = nil
    }

    // DEFAULT is the site's default, so the session is asked which one it got. An ANSI session opens a transaction
    // with its first request and counts DATABASE as DDL, after which only COMMIT is legal, so the setup is committed.
    func prepareSession() throws {
        let (mode, source) = try resolveSessionMode()
        var ranRequest = config.transactionMode == .default
        if let database = config.database, !database.isEmpty {
            _ = try execute(TeradataSchemaQueries.setDatabase(database))
            ranRequest = true
        }
        if mode == .ansi, ranRequest {
            _ = try execute(TeradataTransactionSQL.commit(.ansi))
        }
        socketLock.withLock {
            _sessionMode = mode
            _sessionModeSource = source
            _transaction = TeradataTransactionTracker(mode: mode)
            _defaultDatabase = config.database.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private func resolveSessionMode() throws -> (TeradataTransactionMode, TeradataSessionModeSource) {
        guard config.transactionMode == .default else { return (config.transactionMode, .configured) }
        if let mode = try probeSessionMode(
            TeradataSessionModeProbe.helpSession, read: TeradataSessionModeProbe.mode(fromHelpSession:)
        ) {
            return (mode, .helpSession)
        }
        if let mode = try probeSessionMode(
            TeradataSessionModeProbe.sessionInfo, read: TeradataSessionModeProbe.mode(fromSessionInfo:)
        ) {
            return (mode, .sessionInfoView)
        }
        return (.default, .unresolved)
    }

    // A refusal, or a reply this decoder cannot read, leaves the session usable for the next way of asking.
    private func probeSessionMode(
        _ sql: String,
        read: (TeradataResultSet) -> TeradataTransactionMode?
    ) throws -> TeradataTransactionMode? {
        do {
            return read(try execute(sql))
        } catch TeradataWireError.cancelled {
            throw TeradataWireError.cancelled
        } catch {
            guard isConnected else { throw error }
            return nil
        }
    }

    public func beginTransaction() throws {
        guard let statement = TeradataTransactionSQL.begin(sessionTransactionMode) else { return }
        _ = try execute(statement)
    }

    public func commitTransaction() throws {
        _ = try execute(TeradataTransactionSQL.commit(sessionTransactionMode))
    }

    public func rollbackTransaction() throws {
        do {
            _ = try execute(TeradataTransactionSQL.rollback(sessionTransactionMode))
        } catch TeradataWireError.server(let code, _) where TeradataTransactionSQL.rollbackAnswerCodes.contains(code) {
            // The failure parcel a rollback answers with is its success.
        }
        socketLock.withLock { _transaction.rolledBack() }
    }

    // After DATABASE inside a transaction only the closing statement is legal (ANSI counts it as DDL; Teradata mode
    // is not documented either way), so a switch never joins an open one, and in ANSI it is committed at once.
    // The host re-sends the switch before every statement, so one to where the session already is sends nothing.
    public func switchDatabase(to database: String) throws {
        let (mode, state, current) = socketLock.withLock { (_sessionMode, _transaction.state, _defaultDatabase) }
        guard state != .open else {
            // Teradata compares database names without regard to case.
            guard let current, current.caseInsensitiveCompare(database) == .orderedSame else {
                throw TeradataWireError.openTransactionBlocksDatabaseSwitch
            }
            return
        }
        _ = try execute(TeradataSchemaQueries.setDatabase(database))
        socketLock.withLock { _defaultDatabase = database }
        if mode == .ansi {
            _ = try execute(TeradataTransactionSQL.commit(.ansi))
        }
    }

    public func execute(_ sql: String) throws -> TeradataResultSet {
        var columns: [TeradataColumn] = []
        var rows: [[TeradataValue]] = []
        let activityCount = try perform(sql, onColumns: { columns = $0 }, onRows: { batch in
            rows.append(contentsOf: batch)
            return true
        })
        return TeradataResultSet(columns: columns, rows: rows, activityCount: activityCount)
    }

    // The reply that passes the cap ends the output on the server, so the rows past it are never fetched.
    public func execute(_ sql: String, rowCap: Int?) throws -> TeradataCappedResult {
        guard let rowCap, rowCap > 0 else {
            return TeradataCappedResult(resultSet: try execute(sql), isTruncated: false)
        }
        var columns: [TeradataColumn] = []
        var rows: [[TeradataValue]] = []
        var isTruncated = false
        let activityCount = try perform(sql, onColumns: { columns = $0 }, onRows: { batch in
            guard rows.count + batch.count > rowCap else {
                rows.append(contentsOf: batch)
                return true
            }
            rows.append(contentsOf: batch.prefix(rowCap - rows.count))
            isTruncated = true
            return false
        })
        return TeradataCappedResult(
            resultSet: TeradataResultSet(columns: columns, rows: rows, activityCount: activityCount),
            isTruncated: isTruncated)
    }

    // `onColumns` runs once before any rows, with none for a request that has no result set; false from `onRows` ends the output.
    public func stream(
        _ sql: String,
        onColumns: ([TeradataColumn]) throws -> Void,
        onRows: ([[TeradataValue]]) throws -> Bool
    ) throws {
        _ = try perform(sql, onColumns: onColumns, onRows: onRows)
    }

    private func perform(
        _ sql: String,
        onColumns: ([TeradataColumn]) throws -> Void,
        onRows: ([[TeradataValue]]) throws -> Bool
    ) throws -> Int {
        guard socket != nil else { throw TeradataWireError.connectionFailed("not connected") }
        let kinds = TeradataStatementKind.kinds(in: sql)
        let movesDatabase = TeradataStatementKind.mayMoveDefaultDatabase(sql)
        let requestNumber = nextRequest()
        let body = TeradataMessages.optionsParcel(returnStatementInfo: false).encoded()
            + TeradataMessages.requestParcel(sql: sql).encoded()
            + TeradataMessages.responseParcel().encoded()
        var reader = TeradataResultParser.Reader()
        let outcome: Exchange
        do {
            outcome = try exchange(body, requestNumber: requestNumber) { parcels in
                try reader.read(parcels, onColumns: onColumns, onRows: onRows)
            }
        } catch {
            endRequest()
            // The reply still on its way would be read as the next request's.
            dropTransport()
            throw error
        }
        let stopped = endRequest()
        switch outcome {
        case .notSent:
            throw TeradataWireError.cancelled
        case .refused(let error):
            guard case .server(let code, _)? = error as? TeradataWireError else {
                // Refused by its reader rather than the server, so the request ran.
                recordRan(kinds, movesDatabase: movesDatabase)
                throw error
            }
            let abortRolledBack = socketLock.withLock { () -> Bool in
                let heldTransaction = _transaction.abortRollsBackTransaction
                _transaction.failed(kinds, code: code)
                return heldTransaction
            }
            if stopped, code == Self.userAbortCode {
                throw abortRolledBack ? TeradataWireError.rolledBackByStop : TeradataWireError.cancelled
            }
            throw error
        case .outputEnded where stopped:
            recordRan(kinds, movesDatabase: movesDatabase)
            throw TeradataWireError.cancelled
        case .answered, .outputEnded:
            recordRan(kinds, movesDatabase: movesDatabase)
            try reader.finish(onColumns: onColumns)
            return reader.activityCount
        }
    }

    private func recordRan(_ kinds: [TeradataStatementKind], movesDatabase: Bool) {
        socketLock.withLock {
            _transaction.ran(kinds)
            if movesDatabase { _defaultDatabase = nil }
        }
    }

    private func exchange(
        _ body: [UInt8],
        requestNumber: UInt32,
        consume: ([Parcel]) throws -> Bool
    ) throws -> Exchange {
        let sent = try wireLock.withLock { () -> Bool in
            // A stop that landed before the request went out refuses it, and the session stays as it was.
            let refused = socketLock.withLock { () -> Bool in
                guard !_stopRequested else { return true }
                _phase = .awaitingResponse(requestNumber)
                return false
            }
            guard !refused else { return false }
            try sendEncryptedLocked(kind: .start, body: body, requestNumber: requestNumber)
            return true
        }
        guard sent else { return .notSent }
        while true {
            let batch = try readReply()
            let complete = Self.responseIsComplete(batch)
            // Once the first reply is out an abort no longer takes effect, so a stop ends the output instead.
            socketLock.withLock { _phase = .fetching(requestNumber) }
            let wantsMore: Bool
            do {
                wantsMore = try consume(batch)
            } catch {
                // Ending the output keeps the session; a failed end leaves the rest to be read as the next request's.
                if !complete, (try? endOutput(requestNumber: requestNumber)) == nil { throw error }
                return .refused(error)
            }
            if complete { return .answered }
            if !wantsMore || socketLock.withLock({ _stopRequested }) {
                try endOutput(requestNumber: requestNumber)
                return .outputEnded
            }
            try sendContinue(requestNumber: requestNumber)
        }
    }

    // The Cancel parcel in place of the Response parcel deletes the request's spool, and the server answers with
    // End Request. One that does not throws, and the caller gives the transport up.
    private func endOutput(requestNumber: UInt32) throws {
        try sendEncrypted(kind: .cont, body: TeradataMessages.cancelParcel().encoded(), requestNumber: requestNumber)
        guard Self.responseIsComplete(try readReply()) else {
            throw TeradataWireError.malformed("the server kept answering a cancelled request")
        }
    }

    // A caller's operation, so a stop that lands before its request goes out still reaches it.
    public func beginOperation() {
        socketLock.withLock {
            _operationActive = true
            _stopRequested = false
        }
    }

    public func endOperation() {
        socketLock.withLock {
            _operationActive = false
            _stopRequested = false
        }
    }

    @discardableResult
    private func endRequest() -> Bool {
        socketLock.withLock {
            let stopped = _stopRequested
            _phase = .idle
            _stopRequested = false
            _stoppingRequest = nil
            return stopped
        }
    }

    private func dropTransport() {
        let dropped = socketLock.withLock {
            let transport = _socket
            _socket = nil
            _hasLostConnection = transport != nil
            return transport
        }
        dropped?.close()
    }

    public func disconnect() {
        guard let socket else {
            connectDeadline = nil
            return
        }
        if sessionNumber != 0 {
            wireLock.withLock {
                let message = LanMessage(
                    kind: .logoff, body: TeradataMessages.logoffParcel().encoded(),
                    sessionNumber: sessionNumber, byteVar: 0,
                    authentication: TeradataMessages.authBytes(nextMessage()), hostCharSet: charsetCode)
                try? socket.send(message.encoded())
            }
        }
        socket.close()
        self.socket = nil
        connectDeadline = nil
    }

    // A request the server is still working on is aborted on the session, which rolls back its transaction, answers it
    // with failure 3110 and stays logged on. Past the first reply the request's own loop ends the output instead, and a
    // request not yet sent is refused. A connect has no request to stop, so it gives the transport up, as does an
    // abort that cannot be sent or a server that has not ended the request within the grace.
    public func cancel() {
        let action: StopAction = socketLock.withLock {
            switch _phase {
            case .idle:
                if _operationActive { _stopRequested = true }
                return .nothing
            case .connecting:
                return .close
            case .awaitingResponse(let request):
                _stopRequested = true
                _stoppingRequest = request
                return .abort(request)
            case .fetching(let request):
                _stopRequested = true
                _stoppingRequest = request
                return .endOutput(request)
            }
        }
        switch action {
        case .nothing:
            return
        case .close:
            socket?.cancel()
        case .abort(let request):
            guard sendAbort(for: request) else {
                socket?.cancel()
                return
            }
            closeUnlessEnded(request)
        case .endOutput(let request):
            closeUnlessEnded(request)
        }
    }

    private func closeUnlessEnded(_ request: UInt32) {
        stopDeadlineQueue.asyncAfter(deadline: .now() + stopGrace) { [weak self] in
            guard let self else { return }
            // Shut down under the lock, so a request that ended meanwhile cannot hand the transport to a new one.
            socketLock.withLock {
                guard _stoppingRequest == request else { return }
                _socket?.cancel()
            }
        }
    }

    // A long start still going out holds the lock, and the caller may be the main thread.
    private func sendAbort(for request: UInt32) -> Bool {
        guard wireLock.lock(before: Date(timeIntervalSinceNow: Self.abortLockWait)) else { return false }
        defer { wireLock.unlock() }
        // Past the first reply the request's own loop ends the output; a request already answered needs nothing.
        guard socketLock.withLock({ _phase == .awaitingResponse(request) }) else { return true }
        do {
            try sendEncryptedLocked(kind: .abort, body: TeradataMessages.abortParcel().encoded(), requestNumber: request)
            return true
        } catch {
            return false
        }
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

    private func makeTransport(deadline: TeradataConnectDeadline) throws -> any TeradataTransport {
        guard config.tls.enabled else {
            return try TeradataSocket(host: config.host, port: config.port, deadline: deadline)
        }
        do {
            let transport = try TeradataTLSTransport(
                host: config.host, options: config.tls, deadline: deadline)
            confidentialityBypassed = true
            return transport
        } catch {
            guard config.tls.allowPlaintextFallback else { throw error }
            return try TeradataSocket(host: config.host, port: config.port, deadline: deadline)
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
        let sharedSecret = dh.normalizedSharedSecret(peerPublicKeyBytes: params.serverPublicKey)
        let keyLength = Td2Token.qopKeyLengthBytes(params.qopDer) ?? 32
        aesKey = Array(sharedSecret.prefix(keyLength))
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
        try wireLock.withLock {
            try sendEncryptedLocked(kind: kind, body: body, requestNumber: requestNumber)
        }
    }

    private func sendEncryptedLocked(kind: MessageKind, body: [UInt8], requestNumber: UInt32) throws {
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

public struct TeradataCappedResult: Sendable {
    public let resultSet: TeradataResultSet
    // The answer held more rows than the cap, and its output was ended there.
    public let isTruncated: Bool
}
