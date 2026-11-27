import Foundation
import TableProInfluxDBCore
import TableProSQLGrammar

// The SQL reading tiers a Flux read as an unknown statement, a write, so it would refuse every Flux read on a read-only
// connection. Each statement is read as the driver receives it, through the driver's own routing and Flux reading.
extension QueryClassifier {
    // Flux reads, and writes points with `to()`; it defines no bucket or user.
    static func fluxIsDataStatement(_ statement: String) -> Bool? {
        InfluxStatement.isFlux(statement) ? true : nil
    }

    static func fluxClassification(_ statement: String) -> QueryClassification? {
        guard InfluxStatement.isFlux(statement) else { return nil }
        let reading = FluxScriptReading(InfluxStatement.fluxBody(of: statement))
        return QueryClassification(
            tier: reading.writes ? .write : .safe,
            reachesFilesystemOrExecutesCode: reading.reachesOutside
        )
    }
}
