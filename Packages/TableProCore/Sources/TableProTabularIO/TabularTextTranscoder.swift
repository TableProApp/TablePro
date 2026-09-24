import Foundation

public enum TabularTranscodingError: Error, Equatable, Sendable {
    case undecodable(TabularTextEncoding)
}

public enum TabularTextTranscoder {
    public static func utf8Data(
        from data: Data,
        encoding: TabularTextEncoding,
        skippingPrefix prefixLength: Int
    ) throws -> Data {
        let body = data.dropFirst(min(prefixLength, data.count))
        guard encoding != .utf8 else { return Data(body) }
        guard let text = String(data: Data(body), encoding: encoding.foundationEncoding) else {
            throw TabularTranscodingError.undecodable(encoding)
        }
        return Data(text.utf8)
    }
}
