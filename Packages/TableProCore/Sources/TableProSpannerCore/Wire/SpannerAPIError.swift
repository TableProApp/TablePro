import Foundation

public struct SpannerAPIError: Error, Sendable, Equatable {
    public static let sessionResourceType = "type.googleapis.com/google.spanner.v1.Session"

    public let httpStatus: Int
    public let code: Int?
    public let status: String?
    public let message: String
    public let resourceTypes: [String]

    public init(httpStatus: Int, code: Int?, status: String?, message: String, resourceTypes: [String] = []) {
        self.httpStatus = httpStatus
        self.code = code
        self.status = status
        self.message = message
        self.resourceTypes = resourceTypes
    }

    public var isSessionNotFound: Bool {
        if resourceTypes.contains(Self.sessionResourceType) {
            return true
        }
        return resourceTypes.isEmpty && isNotFound && message.hasPrefix("Session not found")
    }

    public var isAborted: Bool {
        matches(grpcCode: 10, name: "ABORTED")
    }

    public var isUnauthenticated: Bool {
        matches(grpcCode: 16, name: "UNAUTHENTICATED") || httpStatus == 401
    }

    public var isPermissionDenied: Bool {
        matches(grpcCode: 7, name: "PERMISSION_DENIED") || httpStatus == 403
    }

    public var isUnavailable: Bool {
        matches(grpcCode: 14, name: "UNAVAILABLE") || httpStatus == 503
    }

    public var isInvalidArgument: Bool {
        matches(grpcCode: 3, name: "INVALID_ARGUMENT")
    }

    public var isNotFound: Bool {
        matches(grpcCode: 5, name: "NOT_FOUND")
    }

    public static func decode(httpStatus: Int, body: Data) -> SpannerAPIError {
        guard let envelope = try? JSONDecoder().decode(SpannerErrorBody.self, from: body),
              let payload = envelope.payload
        else {
            return SpannerAPIError(httpStatus: httpStatus, code: nil, status: nil, message: fallbackMessage(httpStatus))
        }
        return SpannerAPIError(httpStatus: httpStatus, payload: payload)
    }

    init(httpStatus: Int, payload: SpannerStatusPayload) {
        let message = payload.message ?? ""
        self.init(
            httpStatus: httpStatus,
            code: payload.code,
            status: payload.status,
            message: message.isEmpty ? Self.fallbackMessage(httpStatus) : message,
            resourceTypes: payload.resourceTypes
        )
    }

    private static func fallbackMessage(_ httpStatus: Int) -> String {
        "HTTP \(httpStatus)"
    }

    private func matches(grpcCode: Int, name: String) -> Bool {
        status == name || code == grpcCode
    }
}

internal struct SpannerStatusPayload: Decodable, Sendable {
    let code: Int?
    let status: String?
    let message: String?
    let resourceTypes: [String]

    private enum CodingKeys: String, CodingKey {
        case code
        case status
        case message
        case details
    }

    private struct Detail: Decodable {
        let type: String?
        let resourceType: String?

        private enum CodingKeys: String, CodingKey {
            case type = "@type"
            case resourceType
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeFlexibleIntIfPresent(forKey: .code)
        let statusName = try container.decodeIfPresent(String.self, forKey: .status)
        status = statusName?.isEmpty == false ? statusName : nil
        message = try container.decodeIfPresent(String.self, forKey: .message)
        let details = (try? container.decodeArrayIfPresent(Detail.self, forKey: .details)) ?? []
        resourceTypes = details.compactMap { detail in
            guard detail.type?.hasSuffix("ResourceInfo") == true else { return nil }
            return detail.resourceType
        }
    }
}

internal struct SpannerErrorBody: Decodable {
    let payload: SpannerStatusPayload?

    private enum CodingKeys: String, CodingKey {
        case error
        case code
        case message
    }

    init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() {
            payload = list.isAtEnd ? nil : try list.decode(SpannerErrorBody.self).payload
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.error) {
            payload = try container.decode(SpannerStatusPayload.self, forKey: .error)
            return
        }
        guard container.contains(.code) || container.contains(.message) else {
            payload = nil
            return
        }
        payload = try SpannerStatusPayload(from: decoder)
    }
}
