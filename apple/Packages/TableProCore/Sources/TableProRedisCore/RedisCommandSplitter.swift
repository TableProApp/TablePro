import Foundation

// A command ends at a `;` or a line break outside quotes, and each command's arguments are read as
// RedisArgumentCodec reads them, by the same scan.
public enum RedisCommandSplitter {
    public struct Command: Sendable, Equatable {
        public let text: String
        public let range: NSRange

        public init(text: String, range: NSRange) {
            self.text = text
            self.range = range
        }
    }

    public static func commands(in text: String) -> [Command] {
        var lexer = RedisCommandLexer(text, endsCommands: true, decodesArguments: false)
        var commands: [Command] = []
        while let found = lexer.next() {
            commands.append(command(found, in: text))
        }
        return commands
    }

    // A caret belongs to the command its `;` ends, the command its line ends, or the next command after blanks.
    // The scan stops there, so a caret near the top of a long script reads only that far.
    public static func command(at cursor: Int, in text: String) -> Command? {
        var lexer = RedisCommandLexer(text, endsCommands: true, decodesArguments: false)
        while let found = lexer.next() {
            if cursor <= found.reach { return command(found, in: text) }
        }
        return nil
    }

    private static func command(_ found: RedisCommandLexer.Command, in text: String) -> Command {
        let range = NSRange(location: found.start, length: found.end - found.start)
        return Command(text: (text as NSString).substring(with: range), range: range)
    }
}

// What a driver that runs one command per call reads from its query text.
public enum RedisSingleCommand: Sendable, Equatable {
    case arguments([Data])
    case empty
    case unbalancedQuotes
    case severalCommands

    public static var severalCommandsMessage: String {
        String(localized: "The query holds more than one Redis command. Send one at a time.")
    }

    public init(_ text: String) {
        var lexer = RedisCommandLexer(text, endsCommands: true, decodesArguments: true)
        guard let command = lexer.next() else {
            self = .empty
            return
        }
        guard lexer.next() == nil else {
            self = .severalCommands
            return
        }
        guard let arguments = command.arguments else {
            self = .unbalancedQuotes
            return
        }
        self = .arguments(arguments)
    }
}
