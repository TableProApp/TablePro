import Foundation

public enum HttpResponseEncoder {
    public static func encode(_ head: HttpResponseHead, body: Data?) -> Data {
        var output = "HTTP/1.1 \(head.status.code) \(head.status.reasonPhrase)\r\n"

        let hasContentLength = head.headers.contains("Content-Length")

        for (name, value) in head.headers.all {
            output += "\(name): \(value)\r\n"
        }

        if let body, !hasContentLength {
            output += "Content-Length: \(body.count)\r\n"
        }

        output += "\r\n"

        var data = Data(output.utf8)
        if let body {
            data.append(body)
        }
        return data
    }
}
