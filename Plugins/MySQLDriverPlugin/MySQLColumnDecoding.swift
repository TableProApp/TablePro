//
//  MySQLColumnDecoding.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated internal enum MySQLColumnDecoding: Equatable, Sendable {
    case geometry
    case bit
    case bytes
    case text(MySQLCharacterSet)
    case databendBoolean
    case databendHexBytes

    private static let geometryType: UInt32 = 255

    init(
        typeRaw: UInt32,
        length: UInt = 0,
        charsetnr: UInt32,
        characterSetName: String?,
        flavor: MySQLServerFlavor = .mysql
    ) {
        let isBinary = MariaDBFieldClassifier.isBinary(typeRaw: typeRaw, charset: charsetnr)
        if flavor.isDatabend, DatabendResultShape.isBoolean(typeRaw: typeRaw, length: length) {
            self = .databendBoolean
        } else if flavor.isDatabend, isBinary {
            self = .databendHexBytes
        } else if typeRaw == Self.geometryType {
            self = flavor.isDatabend ? .text(.utf8mb4) : .geometry
        } else if MariaDBFieldClassifier.isBit(typeRaw: typeRaw) {
            self = .bit
        } else if isBinary {
            self = .bytes
        } else if charsetnr == mysqlBinaryCharset {
            self = .text(.utf8mb4)
        } else {
            self = .text(characterSetName.map(MySQLCharacterSet.init(serverName:)) ?? .utf8mb4)
        }
    }

    func decode(_ bytes: UnsafeRawBufferPointer, encoding: MySQLConnectionEncoding) -> PluginCellValue {
        switch self {
        case .geometry:
            return .text(GeometryWKBParser.parse(bytes))
        case .bit:
            return .text(MariaDBFieldClassifier.bitFieldToString(bytes))
        case .bytes:
            return .bytes(Data(bytes))
        case .text(let characterSet):
            return .text(encoding.presentedText(characterSet.decode(bytes)))
        case .databendBoolean:
            return .text(DatabendResultShape.booleanText(fromWireText: MySQLCharacterSet.utf8mb4.decode(bytes)))
        case .databendHexBytes:
            return .bytes(DatabendResultShape.binaryValue(fromWireText: Data(bytes)))
        }
    }
}

nonisolated internal struct MySQLResultColumns {
    private(set) var names: [String] = []
    private(set) var typeCodes: [UInt32] = []
    private(set) var typeNames: [String] = []
    private(set) var decodings: [MySQLColumnDecoding] = []
    private(set) var metadata: [PluginColumnInfo] = []

    var count: Int { names.count }

    mutating func append(
        name: String,
        typeCode: UInt32,
        typeName: String,
        decoding: MySQLColumnDecoding,
        flags: UInt
    ) {
        names.append(name)
        typeCodes.append(typeCode)
        typeNames.append(typeName)
        decodings.append(decoding)
        metadata.append(makeColumnMeta(name: name, typeName: typeName, flags: flags))
    }

    func row(
        encoding: MySQLConnectionEncoding,
        value: (Int) -> UnsafeRawBufferPointer?
    ) -> [PluginCellValue] {
        decodings.indices.map { index in
            guard let bytes = value(index) else { return .null }
            return decodings[index].decode(bytes, encoding: encoding)
        }
    }
}

nonisolated internal func mysqlSessionText(_ bytes: UnsafeRawBufferPointer, encoding: MySQLConnectionEncoding) -> String {
    encoding.presentedText(MySQLCharacterSet.decodeUTF8OrMySQLLatin1(bytes))
}

nonisolated internal func mysqlSessionText(cString: UnsafePointer<CChar>, encoding: MySQLConnectionEncoding) -> String {
    mysqlSessionText(UnsafeRawBufferPointer(start: cString, count: strlen(cString)), encoding: encoding)
}
