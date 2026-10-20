import Foundation

public enum RedisCommandSplitter {
    public struct Command: Sendable, Equatable {
        public let text: String
        public let range: NSRange

        public init(text: String, range: NSRange) {
            self.text = text
            self.range = range
        }
    }

    // The iOS RedisDriver's argument separators, so a split and the parse of each command agree on every character.
    private static let blanks: Set<Character> = [" ", "\t"]
    private static let lineBreaks: Set<Character> = ["\n", "\r", "\r\n"]

    public static func commands(in text: String) -> [Command] {
        var commands: [Command] = []
        scan(text) { command, _ in
            commands.append(command)
            return true
        }
        return commands
    }

    public static func command(at cursor: Int, in text: String) -> Command? {
        var found: Command?
        scan(text) { command, reach in
            guard cursor <= reach else { return true }
            found = command
            return false
        }
        return found
    }

    // `reach` is the last caret offset that belongs to the command: the one right after its `;`, or the end of its line.
    private static func scan(_ text: String, visit: (_ command: Command, _ reach: Int) -> Bool) {
        let source = text as NSString
        var offset = 0
        var start: Int?
        var end = 0
        var quote: Character?
        var escaping = false

        func finish(reach: Int) -> Bool {
            guard let location = start else { return true }
            start = nil
            let range = NSRange(location: location, length: end - location)
            return visit(Command(text: source.substring(with: range), range: range), reach)
        }

        for character in text {
            let location = offset
            offset += character.utf16.count
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ";" {
                guard finish(reach: offset) else { return }
                continue
            } else if lineBreaks.contains(character) {
                guard finish(reach: location) else { return }
                continue
            } else if blanks.contains(character) {
                continue
            }
            if start == nil { start = location }
            end = offset
        }
        _ = finish(reach: offset)
    }
}
