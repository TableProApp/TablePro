//
//  FreeTDSConnection.swift
//  TablePro
//
//  Dual-ownership: compiled into BOTH the macOS MSSQLDriver plugin target
//  (Plugins/MSSQLDriverPlugin/ is its FileSystemSynchronizedRootGroup) AND the
//  iOS TableProMobile target (via the cross-project file reference at
//  TableProMobile/TableProMobile.xcodeproj path = ../Plugins/MSSQLDriverPlugin/...).
//  Edits here ship to both platforms, so keep the API neutral (no PluginKit deps).
//

import CFreeTDS
import Foundation
import os
import TableProMSSQLCore

private let freetdsLogger = Logger(subsystem: "com.TablePro", category: "FreeTDSConnection")

private let freetdsErrorLock = NSLock()
private var freetdsConnectionErrors: [UnsafeRawPointer: String] = [:]
private var freetdsGlobalError = ""

private func freetdsGetError(for dbproc: UnsafeMutablePointer<DBPROCESS>?) -> String {
    freetdsErrorLock.lock()
    defer { freetdsErrorLock.unlock() }
    if let dbproc {
        return freetdsConnectionErrors[UnsafeRawPointer(dbproc)] ?? freetdsGlobalError
    }
    return freetdsGlobalError
}

private func freetdsClearError(for dbproc: UnsafeMutablePointer<DBPROCESS>?) {
    freetdsErrorLock.lock()
    defer { freetdsErrorLock.unlock() }
    if let dbproc {
        freetdsConnectionErrors[UnsafeRawPointer(dbproc)] = nil
    } else {
        freetdsGlobalError = ""
    }
}

private func freetdsSetError(_ msg: String, for dbproc: UnsafeMutablePointer<DBPROCESS>?, overwrite: Bool = false) {
    freetdsErrorLock.lock()
    defer { freetdsErrorLock.unlock() }
    if let dbproc {
        let key = UnsafeRawPointer(dbproc)
        if overwrite || (freetdsConnectionErrors[key]?.isEmpty ?? true) {
            freetdsConnectionErrors[key] = msg
        }
    } else if overwrite || freetdsGlobalError.isEmpty {
        freetdsGlobalError = msg
    }
}

private func freetdsUnregister(_ dbproc: UnsafeMutablePointer<DBPROCESS>) {
    freetdsErrorLock.lock()
    defer { freetdsErrorLock.unlock() }
    freetdsConnectionErrors.removeValue(forKey: UnsafeRawPointer(dbproc))
}

private let freetdsInitOnce: Void = {
    _ = dbinit()
    _ = dberrhandle { dbproc, _, dberr, _, dberrstr, oserrstr in
        var msg = "db-lib error \(dberr)"
        if let s = dberrstr { msg += ": \(String(cString: s))" }
        if let s = oserrstr, String(cString: s) != "Success" { msg += " (os: \(String(cString: s)))" }
        freetdsLogger.error("FreeTDS: \(msg)")
        freetdsSetError(msg, for: dbproc)
        return INT_CANCEL
    }
    _ = dbmsghandle { dbproc, msgno, _, severity, msgtext, _, _, _ in
        guard let text = msgtext else { return 0 }
        let msg = String(cString: text)
        if severity > 10 {
            freetdsSetError(msg, for: dbproc, overwrite: true)
            freetdsLogger.error("FreeTDS msg \(msgno) sev \(severity): \(msg)")
        } else {
            freetdsLogger.debug("FreeTDS msg \(msgno): \(msg)")
        }
        return 0
    }
}()

private func freetdsDispatchAsync<T: Sendable>(
    on queue: DispatchQueue,
    execute work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let result = try work()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func freetdsDispatchAsync(
    on queue: DispatchQueue,
    execute work: @escaping @Sendable () throws -> Void
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.async {
            do {
                try work()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// nonisolated so this file compiles cleanly under TableProMobile's
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor build setting. The class manages its own
// thread safety via a private serial DispatchQueue and NSLock; no main-actor hop needed.
nonisolated final class FreeTDSConnection: @unchecked Sendable {
    private var dbproc: UnsafeMutablePointer<DBPROCESS>?
    private let queue: DispatchQueue
    private let options: MSSQLConnectionOptions
    private let lock = NSLock()
    private var _isConnected = false
    private var _isCancelled = false

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(options: MSSQLConnectionOptions) {
        self.options = options
        self.queue = DispatchQueue(label: "com.TablePro.freetds.\(options.host).\(options.port)", qos: .userInitiated)
        _ = freetdsInitOnce
    }

    func connect() async throws {
        try await freetdsDispatchAsync(on: queue) { [self] in
            try self.connectSync()
        }
    }

    private func connectSync() throws {
        guard let login = dblogin() else {
            throw MSSQLCoreError.connectionFailed("Failed to create login")
        }
        defer { dbloginfree(login) }

        for parameter in MSSQLLoginParameters.build(
            user: options.user,
            password: options.password,
            applicationName: options.applicationName,
            encryptionFlag: options.encryptionFlag,
            database: options.database
        ) {
            _ = dbsetlname(login, parameter.value, parameter.field.dbsetName)
        }
        _ = dbsetlversion(login, UInt8(DBVERSION_74))

        // dbsetlogintime is process-global; setting before dbopen bounds this call. Concurrent
        // connectSync from another FreeTDSConnection would race, but the serial connect queue and
        // the brief window (cleared at function exit) keeps the cost acceptable for interactive use.
        _ = dbsetlogintime(Int32(options.loginTimeoutSeconds))

        freetdsClearError(for: nil)
        let serverName = "\(options.host):\(options.port)"
        guard let proc = dbopen(login, serverName) else {
            let detail = freetdsGetError(for: nil)
            let msg = detail.isEmpty ? "Check host, port, credentials, and TLS settings" : detail
            if let kind = MSSQLTLSClassifier.classifySSLError(detail) {
                throw MSSQLCoreError.tlsHandshakeFailed(kind: kind, serverMessage: detail)
            }
            throw MSSQLCoreError.connectionFailed("Failed to connect to \(options.host):\(options.port): \(msg)")
        }

        self.dbproc = proc
        lock.lock()
        _isConnected = true
        lock.unlock()

        applyMaxTextSize(proc)
    }

    private func applyMaxTextSize(_ proc: UnsafeMutablePointer<DBPROCESS>) {
        guard dbcmd(proc, "SET TEXTSIZE \(Int32.max)") != FAIL, dbsqlexec(proc) != FAIL else {
            freetdsLogger.error("Failed to raise TEXTSIZE; large text columns may be truncated to the 2048-byte default")
            return
        }
        while true {
            let resCode = dbresults(proc)
            if resCode == FAIL || resCode == Int32(NO_MORE_RESULTS) {
                break
            }
        }
    }

    func switchDatabase(_ database: String) async throws {
        try await freetdsDispatchAsync(on: queue) { [self] in
            guard let proc = self.dbproc else {
                throw MSSQLCoreError.notConnected
            }
            if dbuse(proc, database) == FAIL {
                throw MSSQLCoreError.queryFailed("Cannot switch to database '\(database)'")
            }
        }
    }

    func disconnect() {
        let handle = dbproc
        dbproc = nil

        lock.lock()
        _isConnected = false
        lock.unlock()

        if let handle {
            freetdsUnregister(handle)
            queue.async {
                _ = dbclose(handle)
            }
        }
    }

    func cancelCurrentQuery() {
        lock.lock()
        _isCancelled = true
        let proc = dbproc
        lock.unlock()

        guard let proc else { return }
        dbcancel(proc)
    }

    func executeQuery(_ query: String) async throws -> MSSQLRawResult {
        let queryToRun = String(query)
        return try await withTaskCancellationHandler {
            try await freetdsDispatchAsync(on: queue) { [self] in
                try self.executeQuerySync(queryToRun)
            }
        } onCancel: { [weak self] in
            self?.cancelCurrentQuery()
        }
    }

    private func executeQuerySync(_ query: String) throws -> MSSQLRawResult {
        guard let proc = dbproc else {
            throw MSSQLCoreError.notConnected
        }

        _ = dbcanquery(proc)

        lock.lock()
        _isCancelled = false
        lock.unlock()

        freetdsClearError(for: proc)
        if dbcmd(proc, query) == FAIL {
            throw MSSQLCoreError.queryFailed("Failed to prepare query")
        }
        if dbsqlexec(proc) == FAIL {
            let detail = freetdsGetError(for: proc)
            let msg = detail.isEmpty ? "Query execution failed" : detail
            throw MSSQLCoreError.queryFailed(msg)
        }

        var allColumns: [MSSQLColumnDescriptor] = []
        var allRows: [[MSSQLRawCell]] = []
        var firstResultSet = true
        var truncated = false

        while true {
            lock.lock()
            let cancelledBetweenResults = _isCancelled
            if cancelledBetweenResults { _isCancelled = false }
            lock.unlock()
            if cancelledBetweenResults {
                throw CancellationError()
            }

            let resCode = dbresults(proc)
            if resCode == FAIL {
                throw MSSQLCoreError.queryFailed("Query execution failed")
            }
            if resCode == Int32(NO_MORE_RESULTS) {
                break
            }

            let numCols = dbnumcols(proc)
            if numCols <= 0 { continue }

            var descriptors: [MSSQLColumnDescriptor] = []
            for i in 1...numCols {
                let name = dbcolname(proc, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
                let type = Self.columnType(fromFreeTDSToken: dbcoltype(proc, Int32(i)))
                descriptors.append(MSSQLColumnDescriptor(name: name, type: type))
            }

            if firstResultSet {
                allColumns = descriptors
                firstResultSet = false
            }

            while true {
                let rowCode = dbnextrow(proc)
                if rowCode == Int32(NO_MORE_ROWS) { break }
                if rowCode == FAIL { break }

                lock.lock()
                let cancelled = _isCancelled
                if cancelled { _isCancelled = false }
                lock.unlock()
                if cancelled {
                    throw CancellationError()
                }

                var row: [MSSQLRawCell] = []
                for i in 1...numCols {
                    let len = dbdatlen(proc, Int32(i))
                    let colToken = dbcoltype(proc, Int32(i))
                    let colType = descriptors[Int(i - 1)].type
                    if len <= 0 && colToken != Int32(SYBBIT) {
                        row.append(.null)
                    } else if let ptr = dbdata(proc, Int32(i)) {
                        if colType.isBinary {
                            row.append(.bytes(Data(bytes: ptr, count: Int(len))))
                        } else if let str = Self.columnValueAsString(proc: proc, ptr: ptr, srcToken: colToken, srcLen: len, type: colType) {
                            row.append(.string(str))
                        } else {
                            row.append(.null)
                        }
                    } else {
                        row.append(.null)
                    }
                }
                allRows.append(row)
                if allRows.count >= MSSQLRowLimits.emergencyMax {
                    truncated = true
                    break
                }
            }
        }

        let affectedRows = allColumns.isEmpty ? 0 : allRows.count
        return MSSQLRawResult(
            columns: allColumns,
            rows: allRows,
            affectedRows: affectedRows,
            isTruncated: truncated
        )
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<MSSQLStreamElement, Error>.Continuation
    ) async throws {
        let queryToRun = String(query)
        try await withTaskCancellationHandler {
            try await freetdsDispatchAsync(on: queue) { [self] in
                try self.streamQuerySync(queryToRun, continuation: continuation)
            }
        } onCancel: { [weak self] in
            self?.cancelCurrentQuery()
        }
    }

    private func streamQuerySync(
        _ query: String,
        continuation: AsyncThrowingStream<MSSQLStreamElement, Error>.Continuation
    ) throws {
        guard let proc = dbproc else {
            throw MSSQLCoreError.notConnected
        }

        _ = dbcanquery(proc)

        lock.lock()
        _isCancelled = false
        lock.unlock()

        freetdsClearError(for: proc)
        if dbcmd(proc, query) == FAIL {
            throw MSSQLCoreError.queryFailed("Failed to prepare query")
        }
        if dbsqlexec(proc) == FAIL {
            let detail = freetdsGetError(for: proc)
            let msg = detail.isEmpty ? "Query execution failed" : detail
            throw MSSQLCoreError.queryFailed(msg)
        }

        var headerSent = false
        var currentDescriptors: [MSSQLColumnDescriptor] = []

        while true {
            lock.lock()
            let cancelledBetweenResults = _isCancelled || Task.isCancelled
            if cancelledBetweenResults { _isCancelled = false }
            lock.unlock()
            if cancelledBetweenResults {
                continuation.finish(throwing: CancellationError())
                return
            }

            let resCode = dbresults(proc)
            if resCode == FAIL {
                continuation.finish(throwing: MSSQLCoreError.queryFailed("Query execution failed"))
                return
            }
            if resCode == Int32(NO_MORE_RESULTS) {
                break
            }

            let numCols = dbnumcols(proc)
            if numCols <= 0 { continue }

            if !headerSent {
                var descriptors: [MSSQLColumnDescriptor] = []
                for i in 1...numCols {
                    let name = dbcolname(proc, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
                    let type = Self.columnType(fromFreeTDSToken: dbcoltype(proc, Int32(i)))
                    descriptors.append(MSSQLColumnDescriptor(name: name, type: type))
                }
                currentDescriptors = descriptors
                continuation.yield(.header(columns: descriptors))
                headerSent = true
            }

            var batch: [[MSSQLRawCell]] = []
            batch.reserveCapacity(MSSQLRowLimits.streamBatchSize)

            while true {
                let rowCode = dbnextrow(proc)
                if rowCode == Int32(NO_MORE_ROWS) { break }
                if rowCode == FAIL { break }

                lock.lock()
                let cancelled = _isCancelled || Task.isCancelled
                if cancelled { _isCancelled = false }
                lock.unlock()
                if cancelled {
                    if !batch.isEmpty {
                        continuation.yield(.rows(batch))
                    }
                    continuation.finish(throwing: CancellationError())
                    return
                }

                var row: [MSSQLRawCell] = []
                for i in 1...numCols {
                    let len = dbdatlen(proc, Int32(i))
                    let colToken = dbcoltype(proc, Int32(i))
                    let colType = currentDescriptors[Int(i - 1)].type
                    if len <= 0 && colToken != Int32(SYBBIT) {
                        row.append(.null)
                    } else if let ptr = dbdata(proc, Int32(i)) {
                        if colType.isBinary {
                            row.append(.bytes(Data(bytes: ptr, count: Int(len))))
                        } else if let str = Self.columnValueAsString(proc: proc, ptr: ptr, srcToken: colToken, srcLen: len, type: colType) {
                            row.append(.string(str))
                        } else {
                            row.append(.null)
                        }
                    } else {
                        row.append(.null)
                    }
                }
                batch.append(row)
                if batch.count >= MSSQLRowLimits.streamBatchSize {
                    continuation.yield(.rows(batch))
                    batch.removeAll(keepingCapacity: true)
                }
            }

            if !batch.isEmpty {
                continuation.yield(.rows(batch))
            }
        }

        continuation.finish()
    }

    static func columnType(fromFreeTDSToken token: Int32) -> MSSQLColumnType {
        switch token {
        case Int32(SYBCHAR): return .char
        case Int32(SYBVARCHAR): return .varchar
        case Int32(SYBTEXT): return .text
        case Int32(SYBNCHAR): return .nchar
        case Int32(SYBNVARCHAR): return .nvarchar
        case Int32(SYBNTEXT): return .ntext
        case Int32(SYBINT1): return .tinyInt
        case Int32(SYBINT2): return .smallInt
        case Int32(SYBINT4): return .int
        case Int32(SYBINT8): return .bigInt
        case Int32(SYBFLT8): return .float
        case Int32(SYBREAL): return .real
        case Int32(SYBDECIMAL), Int32(SYBNUMERIC): return .decimal
        case Int32(SYBMONEY): return .money
        case Int32(SYBMONEY4): return .smallMoney
        case Int32(SYBBIT): return .bit
        case Int32(SYBBINARY): return .binary
        case Int32(SYBVARBINARY): return .varbinary
        case Int32(SYBIMAGE): return .image
        case Int32(SYBDATETIME): return .dateTime
        case Int32(SYBDATETIME4): return .smallDateTime
        case Int32(SYBDATETIMN): return .dateTimeN
        case 40: return .date
        case 41: return .time
        case 42: return .dateTime2
        case 43: return .dateTimeOffset
        case Int32(SYBUNIQUE): return .uniqueIdentifier
        default: return .unknown(token)
        }
    }

    private static func columnValueAsString(
        proc: UnsafeMutablePointer<DBPROCESS>,
        ptr: UnsafePointer<BYTE>,
        srcToken: Int32,
        srcLen: DBINT,
        type: MSSQLColumnType
    ) -> String? {
        if type.isNarrowString {
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .isoLatin1)
        }
        if type.isUnicodeString {
            return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(srcLen)), encoding: .utf8)
                ?? String(data: Data(bytes: ptr, count: Int(srcLen)), encoding: .utf16LittleEndian)
        }
        let bufSize: DBINT = 256
        var buf = [BYTE](repeating: 0, count: Int(bufSize))
        let converted = buf.withUnsafeMutableBufferPointer { bufPtr in
            dbconvert(proc, srcToken, ptr, srcLen, Int32(SYBCHAR), bufPtr.baseAddress, bufSize)
        }
        guard converted > 0,
              let raw = String(bytes: buf.prefix(Int(converted)), encoding: .utf8)
        else { return nil }
        if type.isDateOrTime {
            return MSSQLDatetimeFormatter.reformat(raw, type: type) ?? raw
        }
        return raw
    }
}

private extension MSSQLLoginField {
    var dbsetName: Int32 {
        switch self {
        case .user: return Int32(DBSETUSER)
        case .password: return Int32(DBSETPWD)
        case .application: return Int32(DBSETAPP)
        case .nationalLanguage: return Int32(DBSETNATLANG)
        case .charset: return Int32(DBSETCHARSET)
        case .encryption: return Int32(DBSETENCRYPT)
        case .database: return Int32(DBSETDBNAME)
        }
    }
}
