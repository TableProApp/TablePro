@testable import TableProMobile
import TableProModels

extension RowWindow {
    // The text each row shows, derived the way the grid and the list derive it.
    var shownValues: [[String?]] {
        rows.map { $0.displayValues() }
    }
}
