import SwiftUI

extension View {
    // `replacement` stands in for the table name, as Select mode's count does, without changing the view's structure.
    func tableTitle(_ table: String, schema: String?, replacement: Text? = nil) -> some View {
        modifier(TableTitle(table: table, schema: schema, replacement: replacement))
    }
}

private struct TableTitle: ViewModifier {
    let table: String
    let schema: String?
    let replacement: Text?

    func body(content: Content) -> some View {
        if let schema {
            if #available(iOS 26.0, *) {
                content
                    .navigationTitle(replacement ?? Text(verbatim: table))
                    .navigationSubtitle(Text(verbatim: schema))
            } else {
                content.navigationTitle(replacement ?? Text(verbatim: "\(schema).\(table)"))
            }
        } else {
            content.navigationTitle(replacement ?? Text(verbatim: table))
        }
    }
}
