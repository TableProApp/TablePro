import Foundation

public enum SQLSnippetMarker {
    public static let token = ";;"

    struct Expansion {
        let text: String
        let cursorOffset: Int  // UTF-16 units, so the caret lands right after multibyte text
    }

    static func expand(_ raw: String) -> Expansion? {
        let mutable = NSMutableString(string: raw)
        let markerRange = mutable.range(of: token)
        guard markerRange.location != NSNotFound else { return nil }
        mutable.deleteCharacters(in: markerRange)
        return Expansion(text: mutable as String, cursorOffset: markerRange.location)
    }
}
