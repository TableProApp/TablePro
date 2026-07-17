import Foundation

enum TeradataMessages {
    static func authBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> UInt64(8 * (7 - $0))) & 0xFF) }
    }

    static func clientConfigParcel() -> Parcel {
        var writer = ByteWriter()
        writer.u32(1)
        writer.u16(2); writer.u16(4); writer.raw([0x14, 0x00, 0x00, 0x00])
        let ttu = Array("TTU 20.00.00".utf8)
        writer.u16(1); writer.u16(UInt16(ttu.count)); writer.raw(ttu)
        writer.u16(4); writer.u16(0)
        writer.u16(8); writer.u16(1); writer.u8(1)
        writer.u16(3); writer.u16(0)
        writer.u16(5); writer.u16(0)
        writer.u16(9); writer.u16(1); writer.u8(1)
        writer.u16(11); writer.u16(1); writer.u8(1)
        writer.u16(14); writer.u16(0)
        writer.u16(15); writer.u16(0)
        return Parcel(.clientConfig, body: writer.bytes)
    }

    static func ssoRequestParcel(method: UInt8, trip: UInt8, token: [UInt8]) -> Parcel {
        var writer = ByteWriter()
        writer.u8(method)
        writer.u8(trip)
        writer.u16(UInt16(token.count))
        writer.raw(token)
        return Parcel(flavor: 132, body: writer.bytes)
    }

    static func assignParcel(username: String) -> Parcel {
        var field = Array(username.utf8.prefix(32))
        field.append(contentsOf: [UInt8](repeating: 0x20, count: 32 - field.count))
        return Parcel(.assign, body: field)
    }

    static func logonParcel(username: String, password: String, account: String?) -> Parcel {
        var text = quoteDouble(username)
        if !password.isEmpty || account?.isEmpty == false { text += "," }
        if !password.isEmpty { text += quoteDouble(password) }
        if let account, !account.isEmpty { text += "," + quoteSingle(account) }
        return Parcel(flavor: 36, body: Array(text.utf8))
    }

    static func sessionOptionsParcel(semantics: UInt8, essEnabled: Bool) -> Parcel {
        let essFlag: UInt8 = essEnabled ? 0x45 : 0
        let essLevel: UInt8 = essEnabled ? 0x01 : 0
        return Parcel(flavor: 114, body: [semantics, 0x4E, 0x4E, 0x44, essFlag, 0x31, 0, 0, essLevel, 0])
    }

    static func connectParcel(partition: String) -> Parcel {
        var body = Array(partition.utf8.prefix(16))
        body.append(contentsOf: [UInt8](repeating: 0x20, count: 16 - body.count))
        body.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        return Parcel(.connect, body: body)
    }

    static func logonDataParcel(host: String, port: UInt16, username: String) -> Parcel {
        let source = "\(host);127.0.0.1:\(port) CID=tablepro \(username) TeraPro 01 LSS"
        return Parcel(flavor: 3, body: Array(source.utf8))
    }

    static func clientAttributesParcel(
        username: String, session: UInt32, charset: UInt8,
        serverIP: String, logMech: String, transactionMode: String, sslMode: String,
        encryptData: Bool = true, database: String?
    ) -> Parcel {
        var writer = ByteWriter()
        func stringAttribute(_ code: UInt16, _ value: String) {
            let bytes = Array(value.utf8)
            writer.u16(code)
            writer.u16(UInt16(1 + bytes.count))
            writer.u8(charset)
            writer.raw(bytes)
        }
        func portAttribute(_ code: UInt16, _ port: UInt16) {
            writer.u16(code); writer.u16(2); writer.u16(port)
        }
        stringAttribute(7, "127.0.0.1")
        stringAttribute(8, "1")
        stringAttribute(9, username)
        stringAttribute(10, "TablePro")
        stringAttribute(11, "macOS")
        stringAttribute(22, "Swift macOS")
        stringAttribute(16, "macOS CryptoKit")
        stringAttribute(25, "C=N;")
        stringAttribute(28, "P")
        stringAttribute(29, "20.0.0.63")
        let ess = "BA=N;CCS=UTF8;CERT=U;CF=0;DP=1025;ENC=\(encryptData ? "Y" : "N");ES=\(session);"
            + "LM=\(logMech);LOB=Y;PART=DBC/SQL;SCS=UTF8;SIP=Y;SSLM=\(sslMode);TM=\(transactionMode);TVD=plain;"
        stringAttribute(30, ess)
        stringAttribute(31, "127.0.0.1")
        portAttribute(32, 50000)
        stringAttribute(33, serverIP)
        portAttribute(34, 1025)
        writer.u16(58); writer.u16(1); writer.u8(2)
        writer.u16(0x7FFF)
        writer.u16(0)
        return Parcel(flavor: 189, body: writer.bytes)
    }

    static func optionsParcel(returnStatementInfo: Bool) -> Parcel {
        Parcel(flavor: 85, body: [0x49, 0x42, 0, 0, 0, returnStatementInfo ? 0x59 : 0, 0, 0, 0, 0])
    }

    static func requestParcel(sql: String) -> Parcel {
        Parcel(flavor: 69, body: Array(sql.utf8))
    }

    static func responseParcel(maxMessageSize: UInt16 = 0xFE50) -> Parcel {
        Parcel(.response, body: [UInt8(maxMessageSize >> 8), UInt8(maxMessageSize & 0xFF)])
    }

    static func logoffParcel() -> Parcel {
        Parcel(.logoff)
    }

    static func charsetCode(fromConfigResponse body: [UInt8], name: String) -> UInt8? {
        let needle = Array(name.utf8)
        guard !needle.isEmpty else { return nil }
        var index = 0
        while index + needle.count <= body.count {
            if Array(body[index..<index + needle.count]) == needle, index >= 2 { return body[index - 2] }
            index += 1
        }
        return nil
    }

    private static func quoteDouble(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func quoteSingle(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
