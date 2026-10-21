import Foundation

// Ranges are UTF-16 offsets into `text`.
public struct EditorSnippet: Equatable {
    public struct Field: Equatable {
        public var ranges: [NSRange]  // more than one range mirrors the same text
        public var choices: [String]

        public init(ranges: [NSRange], choices: [String] = []) {
            self.ranges = ranges
            self.choices = choices
        }
    }

    public var text: String
    public var fields: [Field]  // in the order Tab visits them
    public var finalRange: NSRange?  // nil puts the final caret at the end of the text

    public init(text: String, fields: [Field], finalRange: NSRange? = nil) {
        self.text = text
        self.fields = fields
        self.finalRange = finalRange
    }
}
