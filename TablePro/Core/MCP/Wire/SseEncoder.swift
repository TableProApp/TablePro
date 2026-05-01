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
        var current = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\r" {
                lines.append(current)
                current = ""
                let nextIndex = index + 1
                if nextIndex < characters.count, characters[nextIndex] == "\n" {
                    index = nextIndex + 1
                    continue
                }
                index += 1
                continue
            }
            if char == "\n" {
                lines.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(char)
            index += 1
        }
        lines.append(current)
        return lines
    }
}
