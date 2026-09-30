//
//  EtcdCommandArgument.swift
//  EtcdDriverPlugin
//

import Foundation

internal enum EtcdCommandArgument {
    private static let escapeSequences: [Unicode.Scalar: String] = [
        "\\": "\\\\",
        "\"": "\\\"",
        "\n": "\\n",
        "\r": "\\r"
    ]

    static func quoted(_ value: String) -> String {
        let needsQuoting = value.isEmpty || value.unicodeScalars.contains(where: requiresQuoting)
        guard needsQuoting else { return value }
        var body = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if let escapeSequence = escapeSequences[scalar] {
                body.append(contentsOf: escapeSequence.unicodeScalars)
            } else {
                body.append(scalar)
            }
        }
        return "\"" + String(body) + "\""
    }

    private static func requiresQuoting(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar == "\"" || scalar == "'"
    }
}
