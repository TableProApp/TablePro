//
//  HtmlTableEncoder.swift
//  TablePro
//

import Foundation

enum HtmlTableEncoder {
    static func encode(rows: [[String]], headers: [String]? = nil) -> String {
        var html = "<table>"
        if let headers {
            html += "<tr>"
            for header in headers {
                html += "<th>\(escape(header))</th>"
            }
            html += "</tr>"
        }
        for row in rows {
            html += "<tr>"
            for cell in row {
                html += "<td>\(escape(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</table>"
        return html
    }

    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
