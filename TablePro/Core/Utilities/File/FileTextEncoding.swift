//
//  FileTextEncoding.swift
//  TablePro
//

import Foundation

internal struct FileTextEncoding: Hashable, Sendable {
    let encoding: String.Encoding
    let byteOrderMark: ByteOrderMark?
    let attribute: TextEncodingAttribute?

    static let utf8 = FileTextEncoding(encoding: .utf8)

    init(
        encoding: String.Encoding,
        byteOrderMark: ByteOrderMark? = nil,
        attributeOnDisk: TextEncodingAttribute? = nil
    ) {
        let savedEncoding: String.Encoding = encoding == .ascii ? .utf8 : encoding
        self.encoding = savedEncoding
        self.byteOrderMark = byteOrderMark
        let attributeNamesEncoding = byteOrderMark == nil && attributeOnDisk?.encoding == savedEncoding
        self.attribute = attributeNamesEncoding ? attributeOnDisk : nil
    }

    var displayName: String {
        String.localizedName(of: encoding)
    }

    func bytes(of text: String) -> Data? {
        let byteOrderedEncoding = byteOrderMark?.byteOrderedEncoding ?? encoding.unmarkedByteOrder
        guard let body = text.data(using: byteOrderedEncoding, allowLossyConversion: false) else { return nil }
        guard let byteOrderMark else { return body }
        return Data(byteOrderMark.bytes) + body
    }
}

extension FileTextEncoding: Codable {
    private enum CodingKeys: String, CodingKey {
        case encoding, byteOrderMark, attribute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            encoding: String.Encoding(rawValue: try container.decode(UInt.self, forKey: .encoding)),
            byteOrderMark: try container.decodeIfPresent(ByteOrderMark.self, forKey: .byteOrderMark),
            attributeOnDisk: try container.decodeIfPresent(TextEncodingAttribute.self, forKey: .attribute)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encoding.rawValue, forKey: .encoding)
        try container.encodeIfPresent(byteOrderMark, forKey: .byteOrderMark)
        try container.encodeIfPresent(attribute, forKey: .attribute)
    }
}
