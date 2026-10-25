import Foundation

enum DisplayFormatArray {
    // Readers index the array by column, so it always covers every column of the result.
    static func setting(
        _ format: ValueDisplayFormat?,
        at columnIndex: Int,
        in existing: [ValueDisplayFormat?],
        columnCount: Int
    ) -> [ValueDisplayFormat?] {
        var formats = existing
        while formats.count < max(columnCount, columnIndex + 1) {
            formats.append(nil)
        }
        formats[columnIndex] = format
        return formats
    }
}
