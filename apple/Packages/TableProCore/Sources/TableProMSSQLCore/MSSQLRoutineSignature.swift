import Foundation

// A CLR aggregate (sys.objects.type AF) is listed as a function and PluginKit has no aggregate kind, so its
// signature names it: only the signature reaches the drop, which has to be DROP AGGREGATE.
public enum MSSQLRoutineSignature {
    static let aggregateSuffix = " AGGREGATE"

    public static func listed(parameters: String, objectType: String) -> String {
        let signature = "(\(parameters))"
        return isAggregate(objectType: objectType) ? signature + aggregateSuffix : signature
    }

    // sys.objects.type is char(2), so a code can arrive padded.
    public static func isAggregate(objectType: String) -> Bool {
        objectType.trimmingCharacters(in: .whitespaces).uppercased() == "AF"
    }

    // Every other listed signature ends with its closing parenthesis.
    public static func namesAggregate(_ signature: String?) -> Bool {
        signature?.hasSuffix(aggregateSuffix) ?? false
    }
}
