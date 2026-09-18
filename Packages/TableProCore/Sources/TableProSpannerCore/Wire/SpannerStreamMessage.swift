import Foundation

public enum SpannerStreamMessage: Sendable {
    case partial(SpannerPartialResultSet)
    case failure(SpannerAPIError)

    public static func decode(_ object: Data, httpStatus: Int) throws -> SpannerStreamMessage {
        let dictionary = try SpannerFoundationJSON.object(object)
        if let status = try statusPayload(in: dictionary) {
            return .failure(SpannerAPIError(httpStatus: httpStatus, payload: status))
        }
        return .partial(try SpannerPartialResultSet(foundationObject: dictionary))
    }

    private static func statusPayload(in dictionary: [String: Any]) throws -> SpannerStatusPayload? {
        if let error = dictionary["error"] {
            return try SpannerFoundationJSON.decode(SpannerStatusPayload.self, from: error)
        }
        guard isBareStatus(dictionary) else { return nil }
        return try SpannerFoundationJSON.decode(SpannerStatusPayload.self, from: dictionary)
    }

    private static func isBareStatus(_ dictionary: [String: Any]) -> Bool {
        let looksLikeStatus = dictionary["code"] != nil || dictionary["message"] != nil
        let looksLikeResult = dictionary["metadata"] != nil || dictionary["values"] != nil || dictionary["stats"] != nil
        return looksLikeStatus && !looksLikeResult
    }
}
