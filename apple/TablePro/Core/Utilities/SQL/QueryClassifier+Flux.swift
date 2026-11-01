import Foundation
import TableProInfluxDBCore

// The SQL reading tiers a Flux read as an unknown statement, a write, so it would refuse every Flux read on a read-only
// connection. Each statement is read as the driver receives it, through the driver's own routing and Flux reading.
extension QueryClassifier {
    static func fluxClassification(_ statement: String) -> QueryClassification? {
        guard InfluxStatement.isFlux(statement) else { return nil }
        let reading = FluxScriptReading(InfluxStatement.fluxBody(of: statement))
        return QueryClassification(
            tier: reading.writes ? .write : .safe,
            reachesFilesystemOrExecutesCode: reading.reachesOutside
        )
    }
}
