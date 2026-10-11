import SwiftUI

enum DatabaseTypeStyle {
    @ViewBuilder
    static func iconImage(for glyph: ConnectionGlyph?, size: CGFloat) -> some View {
        let glyph = glyph ?? .fallback
        switch glyph.source {
        case .asset:
            Image(glyph.name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        case .symbol:
            Image(systemName: glyph.name)
                .font(.system(size: size))
        }
    }

    static func iconColor(for type: String) -> Color {
        switch type {
        case "MySQL", "MariaDB": return .orange
        case "TiDB": return .red
        case "Databend": return .blue
        case "OceanBase": return .blue
        case "PostgreSQL", "Redshift": return .blue
        case "SQLite": return .green
        case "Redis": return .red
        case "MongoDB": return .green
        case "ClickHouse": return .yellow
        case "SQL Server": return .indigo
        case "Oracle": return .red
        default: return .gray
        }
    }
}
