import AppKit

enum ERClusterPalette {
    static let colors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal,
        .systemIndigo, .systemRed, .systemMint, .systemBrown, .systemCyan, .systemYellow
    ]

    static func color(for clusterId: Int?) -> NSColor? {
        guard let clusterId, clusterId >= 0 else { return nil }
        return colors[clusterId % colors.count]
    }
}
