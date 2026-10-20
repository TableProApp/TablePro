import Foundation

// The analyzer reads only the text around the caret, so a long script costs a keystroke no more than a short one.
public enum SQLCompletionWindow {
    public static let radius = 5_000

    public static func cut(_ text: NSString, around offset: Int) -> (text: String, start: Int) {
        let caret = min(max(offset, 0), text.length)
        let start = max(0, caret - radius)
        let end = min(text.length, caret + radius)
        return (text.substring(with: NSRange(location: start, length: end - start)), start)
    }
}
