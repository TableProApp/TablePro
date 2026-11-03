import SwiftUI

// A type, a row count or an index kind beside a row's title: secondary text, never a chip.
struct MetadataBadge: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
