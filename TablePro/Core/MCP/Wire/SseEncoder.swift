import Foundation

public enum SseEncoder {
    public static func encode(_ frame: SseFrame) -> Data {
        var output = ""

        if let event = frame.event {
            output += "event: \(event)\n"
        }

        if let id = frame.id {
            output += "id: \(id)\n"
        }

        if let retry = frame.retry {
            output += "retry: \(retry)\n"
        }

        let dataLines = splitLines(frame.data)
        for line in dataLines {
            output += "data: \(line)\n"
        }

        output += "\n"
        return Data(output.utf8)
    }

    private static func splitLines(_ value: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var iterator = value.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        while let scalar = pending ?? iterator.next() {
            pending = nil
            if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                if let next = iterator.next(), next != "\n" {
                    pending = next
                }
                continue
            }
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                continue
            }
            current.append(scalar)
        }

        lines.append(String(current))
        return lines
    }
}
