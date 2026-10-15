import Foundation
import TableProTabularIO

public struct FileTextEncoding: Hashable, Sendable {
    public let encoding: String.Encoding
    public let byteOrderMark: ByteOrderMark?
    public let attribute: TextEncodingAttribute?

    public static let utf8 = FileTextEncoding(encoding: .utf8)

    private static let japaneseEncodings: Set<String.Encoding> = [.shiftJIS, .japaneseEUC]

    public init(
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

    public var displayName: String {
        String.localizedName(of: encoding)
    }

    public func bytes(of text: String) -> Data? {
        let byteOrderedEncoding = byteOrderMark?.byteOrderedEncoding ?? encoding.unmarkedByteOrder
        let storable = Self.japaneseEncodings.contains(encoding) ? TabularJISRoman.folded(text) : text
        guard let body = storable.data(using: byteOrderedEncoding, allowLossyConversion: false) else { return nil }
        guard let byteOrderMark else { return body }
        return Data(byteOrderMark.bytes) + body
    }
}

extension FileTextEncoding: Codable {
    private enum CodingKeys: String, CodingKey {
        case encoding, byteOrderMark, attribute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            encoding: String.Encoding(rawValue: try container.decode(UInt.self, forKey: .encoding)),
            byteOrderMark: try container.decodeIfPresent(ByteOrderMark.self, forKey: .byteOrderMark),
            attributeOnDisk: try container.decodeIfPresent(TextEncodingAttribute.self, forKey: .attribute)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encoding.rawValue, forKey: .encoding)
        try container.encodeIfPresent(byteOrderMark, forKey: .byteOrderMark)
        try container.encodeIfPresent(attribute, forKey: .attribute)
    }
}
