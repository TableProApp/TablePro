import Foundation

public enum MCPMetaKeys {
    public static let progressToken = "progressToken"
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    public static let logLevel = "io.modelcontextprotocol/logLevel"
    public static let subscriptionId = "io.modelcontextprotocol/subscriptionId"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"

    public static let traceParent = "traceparent"
    public static let traceState = "tracestate"
    public static let baggage = "baggage"

    public static let traceContextKeys: Set<String> = [traceParent, traceState, baggage]

    public static func isValid(key: String) -> Bool {
        if traceContextKeys.contains(key) { return true }
        guard let separator = key.lastIndex(of: "/") else { return isValidName(String(key)) }
        let prefix = String(key[key.startIndex..<separator])
        let name = String(key[key.index(after: separator)...])
        return isValidPrefix(prefix) && isValidName(name)
    }

    public static func isReserved(key: String) -> Bool {
        guard let separator = key.lastIndex(of: "/") else { return false }
        let labels = key[key.startIndex..<separator].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let second = labels[1].lowercased()
        return second == "modelcontextprotocol" || second == "mcp"
    }

    private static func isValidPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        let labels = prefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy(isValidLabel)
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last else { return false }
        guard first.isASCIILetter else { return false }
        guard last.isASCIILetter || last.isASCIIDigit else { return false }
        return label.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return true }
        guard let first = name.first, let last = name.last else { return true }
        guard first.isASCIILetter || first.isASCIIDigit else { return false }
        guard last.isASCIILetter || last.isASCIIDigit else { return false }
        return name.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

private extension Character {
    var isASCIILetter: Bool {
        ("a"..."z").contains(self) || ("A"..."Z").contains(self)
    }

    var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
