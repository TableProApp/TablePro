import Foundation

internal enum IdentityPath {
    internal static func joined(_ components: [String], separator: Unicode.Scalar) -> String {
        components
            .map { escaped($0, separator: separator) }
            .joined(separator: String(separator))
    }

    internal static func qualified(name: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return escaped(name, separator: ".") }
        return joined([schema, name], separator: ".")
    }

    internal static func escaped(_ component: String, separator: Unicode.Scalar) -> String {
        guard component.unicodeScalars.contains(where: { $0 == separator || $0 == "\\" }) else {
            return component
        }
        return component
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: String(separator), with: "\\" + String(separator))
    }
}
