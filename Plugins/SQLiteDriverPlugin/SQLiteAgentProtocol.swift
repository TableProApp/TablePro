//
//  SQLiteAgentProtocol.swift
//  TablePro
//

import Foundation

enum SQLiteAgentProtocol {
    static let version: UInt32 = 1
    static let maxFrameLength = 64 * 1_024 * 1_024
    static let backendFieldKey = "sqliteBackend"
    static let agentBackendValue = "agent"
    static let tokenFieldKey = "sqliteAgentToken"
    static let admissionPrefix = "TPRSQL1 "
    static let launcherNoticePrefix = "TPRSQL:"
    static let noPythonNotice = "TPRSQL:NO_PYTHON"

    static func admissionPreamble(token: String) -> Data {
        Data((admissionPrefix + token + "\n").utf8)
    }
}

enum SQLiteAgentValue: Equatable, Sendable {
    case null
    case text(Data)
    case blob(Data)
}

struct SQLiteAgentColumn: Equatable, Sendable {
    let name: String
    let declaredType: String?
}

struct SQLiteAgentFailure: Equatable, Sendable {
    static let unsupportedProtocol: UInt32 = 1
    static let pythonTooOld: UInt32 = 2
    static let libraryUnavailable: UInt32 = 3
    static let openFailed: UInt32 = 4
    static let callbacksUnavailable: UInt32 = 5
    static let malformedRequest: UInt32 = 6

    let code: UInt32
    let message: String
}

enum SQLiteAgentRequest: Equatable, Sendable {
    case hello(protocolVersion: UInt32, path: String, busyTimeoutMilliseconds: UInt32)
    case execute(sql: String, parameters: [SQLiteAgentValue], rowCap: UInt32)
    case cancel
    case heartbeat
    case setBusyTimeout(milliseconds: UInt32)
}

enum SQLiteAgentReply: Equatable, Sendable {
    case ready(protocolVersion: UInt32, sqliteVersion: String, pythonVersion: String)
    case failure(SQLiteAgentFailure)
    case header([SQLiteAgentColumn])
    case rows(columnCount: Int, values: [SQLiteAgentValue])
    case done(changes: Int64, truncated: Bool)
    case error(code: Int32, message: String)
    case launcherNotice(String)
}

enum SQLiteAgentProtocolError: Error, Equatable {
    case frameTooLarge(Int)
    case emptyFrame
    case truncatedPayload
    case trailingBytes
    case unknownOpcode(UInt8)
    case unknownValueTag(UInt8)
    case rowShapeMismatch
}

enum SQLiteAgentOpcode {
    static let hello: UInt8 = 0x01
    static let execute: UInt8 = 0x02
    static let cancel: UInt8 = 0x03
    static let heartbeat: UInt8 = 0x04
    static let setBusyTimeout: UInt8 = 0x05
    static let ready: UInt8 = 0x81
    static let failure: UInt8 = 0x82
    static let header: UInt8 = 0x83
    static let rows: UInt8 = 0x84
    static let done: UInt8 = 0x85
    static let error: UInt8 = 0x86
}

enum SQLiteAgentFrameEncoder {
    static func encode(_ request: SQLiteAgentRequest) -> Data {
        var payload = SQLiteAgentPayloadWriter()
        let opcode: UInt8
        switch request {
        case .hello(let protocolVersion, let path, let busyTimeout):
            opcode = SQLiteAgentOpcode.hello
            payload.appendUInt32(protocolVersion)
            payload.appendString(path)
            payload.appendUInt32(busyTimeout)
        case .execute(let sql, let parameters, let rowCap):
            opcode = SQLiteAgentOpcode.execute
            payload.appendString(sql)
            payload.appendUInt32(UInt32(parameters.count))
            parameters.forEach { payload.appendValue($0) }
            payload.appendUInt32(rowCap)
        case .cancel:
            opcode = SQLiteAgentOpcode.cancel
        case .heartbeat:
            opcode = SQLiteAgentOpcode.heartbeat
        case .setBusyTimeout(let milliseconds):
            opcode = SQLiteAgentOpcode.setBusyTimeout
            payload.appendUInt32(milliseconds)
        }
        return frame(opcode: opcode, payload: payload.bytes)
    }

    static func encode(_ reply: SQLiteAgentReply) -> Data {
        var payload = SQLiteAgentPayloadWriter()
        let opcode: UInt8
        switch reply {
        case .ready(let protocolVersion, let sqliteVersion, let pythonVersion):
            opcode = SQLiteAgentOpcode.ready
            payload.appendUInt32(protocolVersion)
            payload.appendString(sqliteVersion)
            payload.appendString(pythonVersion)
        case .failure(let failure):
            opcode = SQLiteAgentOpcode.failure
            payload.appendUInt32(failure.code)
            payload.appendString(failure.message)
        case .header(let columns):
            opcode = SQLiteAgentOpcode.header
            payload.appendUInt32(UInt32(columns.count))
            for column in columns {
                payload.appendString(column.name)
                if let declaredType = column.declaredType {
                    payload.appendUInt8(1)
                    payload.appendString(declaredType)
                } else {
                    payload.appendUInt8(0)
                }
            }
        case .rows(let columnCount, let values):
            opcode = SQLiteAgentOpcode.rows
            let rowCount = columnCount == 0 ? 0 : values.count / columnCount
            payload.appendUInt32(UInt32(columnCount))
            payload.appendUInt32(UInt32(rowCount))
            values.forEach { payload.appendValue($0) }
        case .done(let changes, let truncated):
            opcode = SQLiteAgentOpcode.done
            payload.appendInt64(changes)
            payload.appendUInt8(truncated ? 1 : 0)
        case .error(let code, let message):
            opcode = SQLiteAgentOpcode.error
            payload.appendUInt32(UInt32(bitPattern: code))
            payload.appendString(message)
        case .launcherNotice(let notice):
            return Data((notice + "\n").utf8)
        }
        return frame(opcode: opcode, payload: payload.bytes)
    }

    private static func frame(opcode: UInt8, payload: [UInt8]) -> Data {
        var writer = SQLiteAgentPayloadWriter()
        writer.appendUInt32(UInt32(payload.count + 1))
        writer.appendUInt8(opcode)
        writer.bytes.append(contentsOf: payload)
        return Data(writer.bytes)
    }
}

struct SQLiteAgentFrameReader {
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var expectsLauncherNotice = true

    mutating func append(_ data: Data) {
        if readIndex > 0, readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        }
        buffer.append(contentsOf: data)
    }

    mutating func nextReply() throws -> SQLiteAgentReply? {
        if expectsLauncherNotice, let notice = try launcherNotice() {
            return notice
        }
        guard let (opcode, payload) = try nextBody() else { return nil }
        var cursor = SQLiteAgentPayloadCursor(bytes: payload)
        let reply = try decodeReply(opcode: opcode, cursor: &cursor)
        guard cursor.isAtEnd else { throw SQLiteAgentProtocolError.trailingBytes }
        return reply
    }

    mutating func nextRequest() throws -> SQLiteAgentRequest? {
        expectsLauncherNotice = false
        guard let (opcode, payload) = try nextBody() else { return nil }
        var cursor = SQLiteAgentPayloadCursor(bytes: payload)
        let request = try decodeRequest(opcode: opcode, cursor: &cursor)
        guard cursor.isAtEnd else { throw SQLiteAgentProtocolError.trailingBytes }
        return request
    }

    private mutating func launcherNotice() throws -> SQLiteAgentReply? {
        let prefix = Array(SQLiteAgentProtocol.launcherNoticePrefix.utf8)
        let available = buffer.count - readIndex
        let comparedCount = min(available, prefix.count)
        guard buffer[readIndex..<(readIndex + comparedCount)].elementsEqual(prefix[0..<comparedCount]) else {
            expectsLauncherNotice = false
            return nil
        }
        guard available >= prefix.count else { return nil }
        guard let newline = buffer[readIndex...].firstIndex(of: 0x0A) else {
            guard available <= 4_096 else { throw SQLiteAgentProtocolError.frameTooLarge(available) }
            return nil
        }
        let notice = String(decoding: buffer[readIndex..<newline], as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        readIndex = newline + 1
        return .launcherNotice(notice)
    }

    private mutating func nextBody() throws -> (UInt8, ArraySlice<UInt8>)? {
        let available = buffer.count - readIndex
        guard available >= 4 else { return nil }
        var lengthCursor = SQLiteAgentPayloadCursor(bytes: buffer[readIndex..<(readIndex + 4)])
        let length = Int(try lengthCursor.readUInt32())
        guard length > 0 else { throw SQLiteAgentProtocolError.emptyFrame }
        guard length <= SQLiteAgentProtocol.maxFrameLength else {
            throw SQLiteAgentProtocolError.frameTooLarge(length)
        }
        guard available >= 4 + length else { return nil }
        expectsLauncherNotice = false
        let bodyStart = readIndex + 4
        let opcode = buffer[bodyStart]
        let payload = buffer[(bodyStart + 1)..<(bodyStart + length)]
        readIndex = bodyStart + length
        return (opcode, payload)
    }

    private func decodeReply(opcode: UInt8, cursor: inout SQLiteAgentPayloadCursor) throws -> SQLiteAgentReply {
        switch opcode {
        case SQLiteAgentOpcode.ready:
            return .ready(
                protocolVersion: try cursor.readUInt32(),
                sqliteVersion: try cursor.readString(),
                pythonVersion: try cursor.readString()
            )
        case SQLiteAgentOpcode.failure:
            return .failure(SQLiteAgentFailure(code: try cursor.readUInt32(), message: try cursor.readString()))
        case SQLiteAgentOpcode.header:
            let count = Int(try cursor.readUInt32())
            var columns: [SQLiteAgentColumn] = []
            columns.reserveCapacity(min(count, 4_096))
            for _ in 0..<count {
                let name = try cursor.readString()
                let declaredType = try cursor.readUInt8() == 1 ? try cursor.readString() : nil
                columns.append(SQLiteAgentColumn(name: name, declaredType: declaredType))
            }
            return .header(columns)
        case SQLiteAgentOpcode.rows:
            let columnCount = Int(try cursor.readUInt32())
            let rowCount = Int(try cursor.readUInt32())
            let (valueCount, overflow) = columnCount.multipliedReportingOverflow(by: rowCount)
            guard !overflow, valueCount <= cursor.remaining else { throw SQLiteAgentProtocolError.rowShapeMismatch }
            var values: [SQLiteAgentValue] = []
            values.reserveCapacity(valueCount)
            for _ in 0..<valueCount {
                values.append(try cursor.readValue())
            }
            return .rows(columnCount: columnCount, values: values)
        case SQLiteAgentOpcode.done:
            return .done(changes: try cursor.readInt64(), truncated: try cursor.readUInt8() == 1)
        case SQLiteAgentOpcode.error:
            return .error(code: Int32(bitPattern: try cursor.readUInt32()), message: try cursor.readString())
        default:
            throw SQLiteAgentProtocolError.unknownOpcode(opcode)
        }
    }

    private func decodeRequest(opcode: UInt8, cursor: inout SQLiteAgentPayloadCursor) throws -> SQLiteAgentRequest {
        switch opcode {
        case SQLiteAgentOpcode.hello:
            return .hello(
                protocolVersion: try cursor.readUInt32(),
                path: try cursor.readString(),
                busyTimeoutMilliseconds: try cursor.readUInt32()
            )
        case SQLiteAgentOpcode.execute:
            let sql = try cursor.readString()
            let count = Int(try cursor.readUInt32())
            guard count <= cursor.remaining else { throw SQLiteAgentProtocolError.truncatedPayload }
            var parameters: [SQLiteAgentValue] = []
            parameters.reserveCapacity(count)
            for _ in 0..<count {
                parameters.append(try cursor.readValue())
            }
            return .execute(sql: sql, parameters: parameters, rowCap: try cursor.readUInt32())
        case SQLiteAgentOpcode.cancel:
            return .cancel
        case SQLiteAgentOpcode.heartbeat:
            return .heartbeat
        case SQLiteAgentOpcode.setBusyTimeout:
            return .setBusyTimeout(milliseconds: try cursor.readUInt32())
        default:
            throw SQLiteAgentProtocolError.unknownOpcode(opcode)
        }
    }
}

private struct SQLiteAgentPayloadWriter {
    var bytes: [UInt8] = []

    mutating func appendUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func appendInt64(_ value: Int64) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func appendBytes<Bytes: Collection>(_ data: Bytes) where Bytes.Element == UInt8 {
        appendUInt32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func appendString(_ string: String) {
        appendBytes(Array(string.utf8))
    }

    mutating func appendValue(_ value: SQLiteAgentValue) {
        switch value {
        case .null:
            appendUInt8(0)
        case .text(let data):
            appendUInt8(1)
            appendBytes(data)
        case .blob(let data):
            appendUInt8(2)
            appendBytes(data)
        }
    }
}

private struct SQLiteAgentPayloadCursor {
    let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    var isAtEnd: Bool { offset == bytes.endIndex }
    var remaining: Int { bytes.endIndex - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw SQLiteAgentProtocolError.truncatedPayload }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SQLiteAgentProtocolError.truncatedPayload }
        defer { offset += 4 }
        return bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readInt64() throws -> Int64 {
        guard remaining >= 8 else { throw SQLiteAgentProtocolError.truncatedPayload }
        defer { offset += 8 }
        let raw = bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(bitPattern: raw)
    }

    mutating func readBytes() throws -> Data {
        let count = Int(try readUInt32())
        guard remaining >= count else { throw SQLiteAgentProtocolError.truncatedPayload }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func readString() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    mutating func readValue() throws -> SQLiteAgentValue {
        let tag = try readUInt8()
        switch tag {
        case 0:
            return .null
        case 1:
            return .text(try readBytes())
        case 2:
            return .blob(try readBytes())
        default:
            throw SQLiteAgentProtocolError.unknownValueTag(tag)
        }
    }
}
