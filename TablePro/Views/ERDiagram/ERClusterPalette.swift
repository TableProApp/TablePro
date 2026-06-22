import SwiftUI

enum ERClusterPalette {
    static let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .brown, .cyan, .yellow
    ]

    static func color(for clusterId: Int?) -> Color? {
        guard let clusterId, clusterId >= 0 else { return nil }
        return colors[clusterId % colors.count]
    }
}
