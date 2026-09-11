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

    private static func snippet(_ body: Data) -> String {
        let text = String(decoding: body.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "empty body" : text
    }
}
