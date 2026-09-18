import SwiftUI
import TableProModels
import UIKit

struct DatabaseIconView: View {
    let type: DatabaseType
    let size: CGFloat
    var tint: Color?

    private static let fallbackSymbol = "cylinder.split.1x2"

    var body: some View {
        if let assetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(color)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: size))
                .foregroundStyle(color)
        }
    }

    private var assetName: String? {
        let name = type.iconName
        guard name.hasSuffix("-icon"), UIImage(named: name) != nil else { return nil }
        return name
    }

    private var symbolName: String {
        let name = type.iconName
        return name.hasSuffix("-icon") ? Self.fallbackSymbol : name
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
