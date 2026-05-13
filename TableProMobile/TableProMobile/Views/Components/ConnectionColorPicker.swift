import SwiftUI
import TableProModels

struct ConnectionColorPicker: View {
    @Binding var selection: ConnectionColor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ConnectionColor.allCases) { color in
                    Button {
                        selection = color
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Self.swiftUIColor(for: color))
                                .frame(width: 28, height: 28)

                            if selection == color {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(color.rawValue))
                }
            }
            .padding(.vertical, 4)
        }
    }

    static func swiftUIColor(for color: ConnectionColor) -> Color {
        switch color {
        case .none: return .gray
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return Color(.systemGray3)
        }
    }
}
