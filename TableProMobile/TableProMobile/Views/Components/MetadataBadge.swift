import SwiftUI

struct MetadataBadge<Background: ShapeStyle>: View {
    let text: String
    var foreground: Color = .secondary
    var background: Background

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

extension MetadataBadge where Background == HierarchicalShapeStyle {
    init(_ text: String, foreground: Color = .secondary) {
        self.init(text: text, foreground: foreground, background: .tertiary)
    }
}
