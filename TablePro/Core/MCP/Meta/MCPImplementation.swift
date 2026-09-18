import Foundation

public struct MCPImplementation: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let version: String
    public let websiteUrl: String?

    public init(name: String, title: String? = nil, version: String, websiteUrl: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
        self.websiteUrl = websiteUrl
    }

    public init?(json: JsonValue?) {
        guard let name = json?["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        title = json?["title"]?.stringValue
        version = json?["version"]?.stringValue ?? ""
        websiteUrl = json?["websiteUrl"]?.stringValue
    }

    public var asJsonValue: JsonValue {
        var fields: [String: JsonValue] = [
            "name": .string(name),
            "version": .string(version)
        ]
        if let title {
            fields["title"] = .string(title)
        }
        if let websiteUrl {
            fields["websiteUrl"] = .string(websiteUrl)
        }
        return .object(fields)
    }
}
