import Foundation

// Each SET must be the only statement in its batch, and stays on the session until turned off.
public enum MSSQLShowplan: String, Sendable, CaseIterable {
    case estimated
    case actual

    public var variantId: String { rawValue }

    public var onStatement: String {
        switch self {
        case .estimated: return "SET SHOWPLAN_XML ON"
        case .actual: return "SET STATISTICS XML ON"
        }
    }

    public var offStatement: String {
        switch self {
        case .estimated: return "SET SHOWPLAN_XML OFF"
        case .actual: return "SET STATISTICS XML OFF"
        }
    }

    public static let planColumnName = "Microsoft SQL Server 2005 XML Showplan"
    static let documentStart = "<ShowPlanXML"

    // A statement error fails the plan: an actual plan of a failed run describes a run that did not finish.
    public func planDocuments(in readout: MSSQLBatchReadout) throws -> [String] {
        if let error = readout.errors.first {
            throw MSSQLCoreError.queryFailed(error.message.text)
        }
        let candidates = readout.resultSets.filter { result in
            result.columns.count == 1 && result.rows.contains { $0.first?.stringValue?.hasPrefix(Self.documentStart) == true }
        }
        // An actual plan also carries the statement's own results, which can be plan XML read from the plan cache, so
        // the server's plan column wins; a result set named otherwise counts only when none carries that name.
        let named = candidates.filter { $0.columns[0].name.caseInsensitiveCompare(Self.planColumnName) == .orderedSame }
        let planResults = self == .actual && !named.isEmpty ? named : candidates
        let documents = planResults
            .flatMap { $0.rows.compactMap { $0.first?.stringValue } }
            .filter { $0.hasPrefix(Self.documentStart) }
        guard !documents.isEmpty else {
            throw MSSQLCoreError.queryFailed(String(localized: "SQL Server returned no plan for this statement."))
        }
        return documents
    }

    public static var resetFailedMessage: String {
        String(localized: "The plan setting could not be turned off again, so the connection was closed. Reconnect to go on.")
    }
}
