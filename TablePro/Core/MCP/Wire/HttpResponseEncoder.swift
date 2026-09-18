import Foundation

public enum HttpResponseEncoder {
    public static func encode(_ head: HttpResponseHead, body: Data?) -> Data {
        var output = statusLine(head.status)

        for (name, value) in head.headers.all {
            output += "\(name): \(value)\r\n"
        }

        if !head.headers.contains("Content-Length"), allowsContentLength(head.status) {
            output += "Content-Length: \(body?.count ?? 0)\r\n"
        }

        output += "\r\n"

        var data = Data(output.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    public static func encodeStreamHead(_ head: HttpResponseHead) -> Data {
        var output = statusLine(head.status)
        for (name, value) in head.headers.all {
            output += "\(name): \(value)\r\n"
        }
        output += "\r\n"
        return Data(output.utf8)
    }

    private static func statusLine(_ status: HttpStatus) -> String {
        "HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\n"
    }

    private static func allowsContentLength(_ status: HttpStatus) -> Bool {
        status.code != 204 && status.code != 304 && !(100...199).contains(status.code)
    }
}
