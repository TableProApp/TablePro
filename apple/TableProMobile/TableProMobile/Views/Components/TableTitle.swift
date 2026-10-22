import SwiftUI

extension View {
    func tableTitle(_ table: String, schema: String?) -> some View {
        modifier(TableTitle(table: table, schema: schema))
    }
}

private struct TableTitle: ViewModifier {
    let table: String
    let schema: String?

    func body(content: Content) -> some View {
        if let schema {
            if #available(iOS 26.0, *) {
                content
                    .navigationTitle(Text(verbatim: table))
                    .navigationSubtitle(Text(verbatim: schema))
            } else {
                content.navigationTitle(Text(verbatim: "\(schema).\(table)"))
            }
        } else {
            content.navigationTitle(Text(verbatim: table))
        }
    }
}
