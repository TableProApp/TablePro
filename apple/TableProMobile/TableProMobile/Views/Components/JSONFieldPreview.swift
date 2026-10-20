import SwiftUI
import TableProTabularIO

struct JSONFieldPreview: View {
    private static let lineLimit = 12
    private static let scalarLimit = 4_000

    let text: String

    @State private var cache = ExcerptCache()

    var body: some View {
        Text(verbatim: cache.excerpt(for: text))
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(Self.lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // One more line than the limit, so the text shows its truncation mark when the value goes on.
    static func excerpt(of text: String) -> String {
        let pretty = JSONPrettyPrinter.format(text) ?? text
        let scalars = pretty.unicodeScalars
        var index = scalars.startIndex
        var lineBreaks = 0
        var count = 0
        while index != scalars.endIndex, count < scalarLimit {
            if scalars[index] == "\n" {
                lineBreaks += 1
                if lineBreaks > lineLimit { break }
            }
            count += 1
            scalars.formIndex(after: &index)
        }
        return String(scalars[..<index])
    }

    private final class ExcerptCache {
        private var source: String?
        private var excerpt = ""

        func excerpt(for text: String) -> String {
            if source != text {
                source = text
                excerpt = JSONFieldPreview.excerpt(of: text)
            }
            return excerpt
        }
    }
}
