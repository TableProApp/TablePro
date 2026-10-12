import Foundation

public protocol PubliclyLoggableError: Error {
    var publicLogDescription: String { get }
}

public enum LogRedaction {
    private static let maximumDomainLength = 64
    private static let identifierPunctuation: Set<Unicode.Scalar> = [".", "_", "-"]

    public static func publicDescription(of error: Error) -> String {
        if let loggable = error as? PubliclyLoggableError {
            return loggable.publicLogDescription
        }

        let typeName = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)

        guard mirror.displayStyle == .enum else {
            return bridgedShape(of: error as NSError, typeName: typeName)
        }
        if let caseName = mirror.children.first?.label {
            return "\(typeName).\(caseName)"
        }
        guard !describesItself(type(of: error)) else { return typeName }
        return "\(typeName).\(error)"
    }

    private static func bridgedShape(of error: NSError, typeName: String) -> String {
        let domain = error.domain
        guard !domain.hasSuffix(typeName), isConstantIdentifier(domain) else {
            return "\(typeName)(\(error.code))"
        }
        return "\(typeName)(\(domain), \(error.code))"
    }

    private static func isConstantIdentifier(_ domain: String) -> Bool {
        let scalars = domain.unicodeScalars
        guard domain.utf8.count <= maximumDomainLength, let first = scalars.first, isASCIILetter(first) else {
            return false
        }
        return scalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || identifierPunctuation.contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func describesItself(_ type: any Error.Type) -> Bool {
        type is CustomStringConvertible.Type || type is CustomDebugStringConvertible.Type
    }
}
