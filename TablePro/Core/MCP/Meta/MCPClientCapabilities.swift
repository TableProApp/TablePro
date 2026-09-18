import Foundation

public struct MCPClientCapabilities: Sendable, Equatable {
    public let supportsElicitation: Bool
    public let supportsSampling: Bool
    public let supportsRoots: Bool
    public let elicitationModes: Set<String>
    public let extensions: [String: JsonValue]
    public let raw: JsonValue

    public init(
        supportsElicitation: Bool = false,
        supportsSampling: Bool = false,
        supportsRoots: Bool = false,
        elicitationModes: Set<String> = [],
        extensions: [String: JsonValue] = [:],
        raw: JsonValue = .object([:])
    ) {
        self.supportsElicitation = supportsElicitation
        self.supportsSampling = supportsSampling
        self.supportsRoots = supportsRoots
        self.elicitationModes = elicitationModes
        self.extensions = extensions
        self.raw = raw
    }

    public static let none = MCPClientCapabilities()

    public init(json: JsonValue) {
        raw = json
        supportsElicitation = json["elicitation"] != nil
        supportsSampling = json["sampling"] != nil
        supportsRoots = json["roots"] != nil
        if let modes = json["elicitation"]?["modes"]?.arrayValue {
            elicitationModes = Set(modes.compactMap(\.stringValue))
        } else {
            elicitationModes = supportsElicitation ? ["form"] : []
        }
        extensions = json["extensions"]?.objectValue ?? [:]
    }

    public func supportsElicitationMode(_ mode: String) -> Bool {
        guard supportsElicitation else { return false }
        return elicitationModes.isEmpty || elicitationModes.contains(mode)
    }
}
