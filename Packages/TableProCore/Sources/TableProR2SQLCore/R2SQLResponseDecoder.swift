import Foundation

public enum R2SQLResponseDecoder {
    public static func decode(_ response: R2SQLHTTPResponse) throws -> R2SQLResult {
        let envelope: R2SQLEnvelope
        do {
            envelope = try JSONDecoder().decode(R2SQLEnvelope.self, from: response.body)
        } catch {
            throw R2SQLError.malformedResponse(status: response.statusCode, detail: snippet(response.body))
        }

        guard envelope.success else {
            switch response.statusCode {
            case 401, 403:
                throw R2SQLError.authentication(status: response.statusCode, errors: envelope.errors)
            default:
                throw R2SQLError.api(status: response.statusCode, errors: envelope.errors)
            }
        }
        return envelope.result ?? R2SQLResult(schema: [], rows: [])
    }

    /// The body of a response that failed to decode, shown to the reader as a diagnostic. It can be anything the
    /// endpoint sent, so it is decoded leniently on purpose: a failable initializer would answer nil for exactly the
    /// malformed body the reader needs to see.
    private static func snippet(_ body: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: body.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "empty body" : text
    }
}
