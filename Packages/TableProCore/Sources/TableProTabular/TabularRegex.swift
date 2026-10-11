import Foundation

public enum TabularRegex {
    public static func firstMatch(_ expression: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        var found: NSTextCheckingResult?
        enumerate(expression, in: text) { match in
            found = match
            return false
        }
        return found
    }

    public static func matches(_ expression: NSRegularExpression, in text: String) -> [NSTextCheckingResult]? {
        var results: [NSTextCheckingResult] = []
        let completed = enumerate(expression, in: text) { match in
            results.append(match)
            return true
        }
        return completed ? results : nil
    }

    @discardableResult
    private static func enumerate(
        _ expression: NSRegularExpression,
        in text: String,
        _ body: (NSTextCheckingResult) -> Bool
    ) -> Bool {
        var cancelled = false
        let range = NSRange(location: 0, length: (text as NSString).length)
        expression.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
            if Task.isCancelled {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let match, !body(match) else { return }
            stop.pointee = true
        }
        return !cancelled
    }
}
