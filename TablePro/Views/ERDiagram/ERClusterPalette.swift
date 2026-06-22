import SwiftUI

enum ERClusterPalette {
    static let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .brown, .cyan, .yellow
    ]

    static func color(forCluster clusterId: Int) -> Color? {
        guard clusterId >= 0 else { return nil }
        return colors[clusterId % colors.count]
    }
}
