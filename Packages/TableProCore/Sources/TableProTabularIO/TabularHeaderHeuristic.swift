import Foundation

public enum TabularHeaderHeuristic {
    public static func isLabel(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        !bytes.isEmpty && TabularNumberGrammar.shape(of: bytes) == nil
    }

    public static func looksLikeHeader(labelCount: Int, cellCount: Int) -> Bool {
        cellCount > 0 && labelCount * 2 >= cellCount
    }

    public static func firstRowLooksLikeHeader(of source: some TabularSource) -> Bool {
        guard source.rowCount > 0, source.columnCount > 0 else { return false }
        var labels = 0
        source.scan(columns: Array(0..<source.columnCount), rows: CollectionOfOne(0)) { _, cells in
            for index in 0..<cells.count where cells.kinds[index] == .text && isLabel(cells.bytes[index]) {
                labels += 1
            }
            return false
        }
        return looksLikeHeader(labelCount: labels, cellCount: source.columnCount)
    }
}
