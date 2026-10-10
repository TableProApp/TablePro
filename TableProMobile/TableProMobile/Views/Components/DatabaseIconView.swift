import SwiftUI
import TableProModels

struct DatabaseIconView: View {
    let type: DatabaseType
    var iconName: String?
    let size: CGFloat
    var tint: Color?

    var body: some View {
        let glyph = LibraryGlyph.connectionGlyph(type: type, iconName: iconName)
        switch glyph.source {
        case .asset:
            Image(glyph.name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(color)
        case .symbol:
            Image(systemName: glyph.name)
                .font(.system(size: size))
                .foregroundStyle(color)
        }
    }

    var color: Color {
        tint ?? Self.color(for: type)
    }

    static func color(for type: DatabaseType) -> Color {
        switch type {
        case .mysql, .mariadb: return .orange
        case .tidb: return .red
        case .databend: return .blue
        case .oceanbase: return .blue
        case .postgresql, .redshift: return .blue
        case .sqlite: return .green
        case .redis: return .red
        case .mongodb: return .green
        case .clickhouse: return .yellow
        case .mssql: return .indigo
        case .oracle: return .red
        default: return .gray
        }
    }
}
