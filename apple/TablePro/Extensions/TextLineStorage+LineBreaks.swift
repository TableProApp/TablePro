import Foundation
import TableProTextEngine

extension TextLineStorage where Data == TextLine {
    // The layout manager updates its lines edit by edit and can split or join a CR LF pair an edit crosses, after
    // which its lines no longer end where the text's line breaks do. Without a CR in the text that cannot happen.
    func breaksLines(like text: NSString) -> Bool {
        guard length == text.length else { return false }
        let lineBreaks = CharacterSet(charactersIn: "\r\n")
        var start = 0
        var index = 0
        while let line = getLine(atIndex: index), line.range.location == start {
            let rest = NSRange(location: start, length: text.length - start)
            let found = text.rangeOfCharacter(from: lineBreaks, options: .literal, range: rest)
            guard found.location != NSNotFound else {
                return NSMaxRange(line.range) == text.length && index == count - 1
            }
            var end = NSMaxRange(found)
            if text.character(at: found.location) == 0x0D, end < text.length, text.character(at: end) == 0x0A {
                end += 1
            }
            guard NSMaxRange(line.range) == end else { return false }
            start = end
            index += 1
        }
        return false
    }
}
