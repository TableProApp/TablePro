import Foundation

public struct HttpStatus: Sendable, Equatable {
    public let code: Int
    public let reasonPhrase: String

    public init(code: Int, reasonPhrase: String) {
        self.code = code
        self.reasonPhrase = reasonPhrase
    }

    public static let ok = HttpStatus(code: 200, reasonPhrase: "OK")
    public static let accepted = HttpStatus(code: 202, reasonPhrase: "Accepted")
    public static let noContent = HttpStatus(code: 204, reasonPhrase: "No Content")
    public static let badRequest = HttpStatus(code: 400, reasonPhrase: "Bad Request")
    public static let unauthorized = HttpStatus(code: 401, reasonPhrase: "Unauthorized")
    public static let forbidden = HttpStatus(code: 403, reasonPhrase: "Forbidden")
    public static let notFound = HttpStatus(code: 404, reasonPhrase: "Not Found")
    public static let methodNotAllowed = HttpStatus(code: 405, reasonPhrase: "Method Not Allowed")
    public static let notAcceptable = HttpStatus(code: 406, reasonPhrase: "Not Acceptable")
    public static let payloadTooLarge = HttpStatus(code: 413, reasonPhrase: "Payload Too Large")
    public static let unsupportedMediaType = HttpStatus(code: 415, reasonPhrase: "Unsupported Media Type")
    public static let tooManyRequests = HttpStatus(code: 429, reasonPhrase: "Too Many Requests")
    public static let internalServerError = HttpStatus(code: 500, reasonPhrase: "Internal Server Error")
    public static let notImplemented = HttpStatus(code: 501, reasonPhrase: "Not Implemented")
    public static let serviceUnavailable = HttpStatus(code: 503, reasonPhrase: "Service Unavailable")
}

public struct HttpResponseHead: Sendable, Equatable {
    public let status: HttpStatus
    public let headers: HttpHeaders

    public init(status: HttpStatus, headers: HttpHeaders) {
        self.status = status
        self.headers = headers
    }
}
