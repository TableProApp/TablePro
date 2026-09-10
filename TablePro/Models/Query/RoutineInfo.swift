import Foundation

struct RoutineInfo: Identifiable, Hashable, Sendable {
    let name: String
    let schema: String?
    let kind: Kind

    /// The parameter list as the engine spells it, parentheses included: `(date)`. This is what
    /// separates two overloads of one name, and it is never the return type.
    let argumentSignature: String?
    let returnType: String?
    let language: String?

    /// The driver's own key for re-addressing this routine when asked for its source. Opaque here.
    let identity: String?

    /// The source, when the listing already returned it. Never part of `id`: a definition that
    /// changes must not change which routine this is, or a reload stops matching its own object.
    let definition: String?
    let attributes: [ObjectAttribute]

    enum Kind: String, Sendable, CaseIterable {
        case procedure = "PROCEDURE"
        case function = "FUNCTION"

        var sidebarObjectKind: SidebarObjectKind {
            switch self {
            case .procedure: return .procedure
            case .function:  return .function
            }
        }
    }

    init(
        name: String,
        kind: Kind,
        schema: String? = nil,
        argumentSignature: String? = nil,
        returnType: String? = nil,
        language: String? = nil,
        identity: String? = nil,
        definition: String? = nil,
        attributes: [ObjectAttribute] = []
    ) {
        self.name = name
        self.kind = kind
        self.schema = schema
        self.argumentSignature = argumentSignature
        self.returnType = returnType
        self.language = language
        self.identity = identity
        self.definition = definition
        self.attributes = attributes
    }

    var qualifiedName: String {
        if let schema, !schema.isEmpty {
            return "\(schema).\(name)"
        }
        return name
    }

    /// The engine's own key wins, because it is the only value guaranteed to separate two routines
    /// the engine considers distinct. The signature is the readable fallback.
    var discriminator: String? {
        if let identity, !identity.isEmpty { return identity }
        guard let argumentSignature, !argumentSignature.isEmpty else { return nil }
        return argumentSignature
    }

    var id: String {
        guard let discriminator else {
            return "\(kind.rawValue)_\(qualifiedName)"
        }
        return "\(kind.rawValue)_\(qualifiedName)_\(discriminator)"
    }

    /// Equality follows `id` alone so a Set, a Dictionary and an outline view can never disagree
    /// about how many routines there are. Excluding the discriminator collapsed two overloads into
    /// one entry, which is how one of a pair of PostgreSQL overloads became unreachable.
    static func == (lhs: RoutineInfo, rhs: RoutineInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
