//
//  DatabaseIconView.swift
//  TableProMobile
//

import SwiftUI
import TableProModels

struct DatabaseIconView: View {
    let type: DatabaseType
    let size: CGFloat

    var body: some View {
        let name = type.iconName
        if name.hasSuffix("-icon") {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(color)
        } else {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(color)
        }
    }

    var color: Color {
        Self.color(for: type)
    }

    static func color(for type: DatabaseType) -> Color {
        switch type {
        case .mysql, .mariadb: return .orange
        case .postgresql, .redshift: return .blue
        case .sqlite: return .green
        case .redis: return .red
        case .mongodb: return .green
        case .clickhouse: return .yellow
        case .mssql: return .indigo
        default: return .gray
        }
    }
}
