import Foundation

struct XLSXSheetReader {
    private enum CellType {
        case number
        case sharedString
        case inlineString
        case formulaString
        case boolean
        case error
        case isoDate
    }

    private enum CellValue {
        case none
        case direct(Range<Int>)
        case decoded
    }

    private let styles: XLSXStyleSheet
    private let sharedStringCount: Int
    private let dateSystem: XLSXDateSystem
    private var builders: [XLSXColumnBuilder] = []
    private let arena = XLSXByteHeapBuilder()
    private var merges: [XLSXCellRange] = []
    private var currentRow = -1
    private var nextColumn = 0
    private var valueScratch: [UInt8] = []
    private var inlineScratch: [UInt8] = []

    init(styles: XLSXStyleSheet, sharedStringCount: Int, dateSystem: XLSXDateSystem) {
        self.styles = styles
        self.sharedStringCount = sharedStringCount
        self.dateSystem = dateSystem
    }

    static func read(
        _ workbook: XLSXWorkbook,
        sheet: XLSXSheet,
        chunkSize: Int,
        progress: ((Double) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> XLSXSheetSource {
        guard let entry = workbook.archive.entry(matching: sheet.partPath) else {
            throw ZipArchive.Failure.entryNotFound(sheet.partPath)
        }
        var reader = XLSXSheetReader(
            styles: workbook.styles,
            sharedStringCount: workbook.sharedStrings.count,
            dateSystem: workbook.dateSystem
        )
        try XLSXStreamingParse.run(
            workbook.archive,
            entry: entry,
            chunkSize: chunkSize,
            progress: progress,
            isCancelled: isCancelled
        ) { buffer, isFinal in
            reader.consume(buffer, isFinal: isFinal)
        }
        progress?(1)
        return reader.finish(name: sheet.name, sharedStrings: workbook.sharedStrings)
    }

    mutating func consume(_ buffer: UnsafeBufferPointer<UInt8>, isFinal: Bool) -> Int {
        var scanner = XMLByteScanner(bytes: buffer, isFinal: isFinal)
        while true {
            let mark = scanner.position
            switch scanner.next() {
            case .startTag(let name, let attributes, let isSelfClosing):
                let local = scanner.localName(of: name)
                if scanner.matches(local, "c") {
                    guard readCell(&scanner, attributes: attributes, isSelfClosing: isSelfClosing) else { return mark }
                } else if scanner.matches(local, "row") {
                    beginRow(scanner, attributes: attributes)
                } else if scanner.matches(local, "mergeCell") {
                    recordMerge(scanner, attributes: attributes)
                }
            case .incomplete:
                return mark
            case .end:
                return scanner.position
            case .endTag, .text, .characterData, .markup:
                continue
            }
        }
    }

    mutating func finish(name: String, sharedStrings: XLSXSharedStrings) -> XLSXSheetSource {
        for merge in merges {
            for column in merge.columns where column < builders.count {
                let kept = column == merge.start.column ? merge.start.row : nil
                builders[column].clear(rows: merge.rows, keeping: kept)
            }
        }
        var rowBounds: ClosedRange<Int>?
        var columnBounds: ClosedRange<Int>?
        for column in builders.indices {
            guard let occupied = builders[column].occupiedRows() else { continue }
            rowBounds = rowBounds.map { min($0.lowerBound, occupied.lowerBound)...max($0.upperBound, occupied.upperBound) } ?? occupied
            columnBounds = columnBounds.map { $0.lowerBound...column } ?? column...column
        }
        let arenaHeap = arena.finish()
        guard let rowBounds, let columnBounds else {
            return XLSXSheetSource(
                name: name,
                layout: XLSXSheetSource.Layout(rowCount: 0, firstRowIndex: 0, firstColumnIndex: 0, mergedRanges: merges),
                columns: [],
                arena: arenaHeap,
                sharedStrings: sharedStrings,
                dateSystem: dateSystem
            )
        }
        var stores: [XLSXColumnStore] = []
        stores.reserveCapacity(columnBounds.count)
        for column in columnBounds {
            stores.append(builders[column].makeStore(rowOrigin: rowBounds.lowerBound))
        }
        builders = []
        return XLSXSheetSource(
            name: name,
            layout: XLSXSheetSource.Layout(
                rowCount: rowBounds.count,
                firstRowIndex: rowBounds.lowerBound,
                firstColumnIndex: columnBounds.lowerBound,
                mergedRanges: merges
            ),
            columns: stores,
            arena: arenaHeap,
            sharedStrings: sharedStrings,
            dateSystem: dateSystem
        )
    }

    private mutating func beginRow(_ scanner: XMLByteScanner, attributes: Range<Int>) {
        let declared = scanner.attribute("r", in: attributes).flatMap(scanner.integer)
        if let declared, declared >= 1, declared <= XLSXCellReference.maximumRowCount {
            currentRow = declared - 1
        } else {
            currentRow += 1
        }
        nextColumn = 0
    }

    private mutating func recordMerge(_ scanner: XMLByteScanner, attributes: Range<Int>) {
        guard let reference = scanner.attribute("ref", in: attributes),
              let range = XLSXCellRange.parse(scanner.bytes, reference) else { return }
        merges.append(range)
    }

    private mutating func readCell(_ scanner: inout XMLByteScanner, attributes: Range<Int>, isSelfClosing: Bool) -> Bool {
        var reference: Range<Int>?
        var typeRange: Range<Int>?
        var style = 0
        scanner.forEachAttribute(in: attributes) { name, value in
            guard name.count == 1 else { return }
            switch scanner.bytes[name.lowerBound] {
            case 0x72: reference = value
            case 0x74: typeRange = value
            case 0x73: style = scanner.integer(value) ?? 0
            default: break
            }
        }
        let position = cellPosition(scanner, reference: reference)
        guard !isSelfClosing else {
            advance(past: position)
            return true
        }
        let type = cellType(scanner, typeRange)
        var value = CellValue.none
        var hasInlineText = false
        while true {
            switch scanner.next() {
            case .startTag(let child, _, let childIsSelfClosing):
                if childIsSelfClosing { continue }
                let local = scanner.localName(of: child)
                if scanner.matches(local, "v") {
                    guard let collected = collectValue(&scanner, unescapingOOXML: type == .formulaString) else { return false }
                    value = collected
                } else if scanner.matches(local, "is") {
                    inlineScratch.removeAll(keepingCapacity: true)
                    guard XLSXRichText.read(&scanner, closing: "is", into: &inlineScratch) else { return false }
                    hasInlineText = true
                } else if !scanner.skipElement(named: child) {
                    return false
                }
            case .endTag:
                advance(past: position)
                if hasInlineText {
                    storeInlineText(at: position)
                } else {
                    store(scanner, position: position, type: type, style: style, value: value)
                }
                return true
            case .text, .characterData, .markup:
                continue
            case .incomplete, .end:
                return false
            }
        }
    }

    private func cellPosition(_ scanner: XMLByteScanner, reference: Range<Int>?) -> (row: Int, column: Int)? {
        let row = max(currentRow, 0)
        guard let reference else {
            return nextColumn < XLSXCellReference.maximumColumnCount ? (row, nextColumn) : nil
        }
        guard let parsed = XLSXCellReference.parse(scanner.bytes, reference) else { return nil }
        return (parsed.row ?? row, parsed.column)
    }

    private mutating func advance(past position: (row: Int, column: Int)?) {
        guard let position else { return }
        nextColumn = position.column + 1
    }

    private func cellType(_ scanner: XMLByteScanner, _ range: Range<Int>?) -> CellType {
        guard let range else { return .number }
        if scanner.matches(range, "s") { return .sharedString }
        if scanner.matches(range, "str") { return .formulaString }
        if scanner.matches(range, "inlineStr") { return .inlineString }
        if scanner.matches(range, "b") { return .boolean }
        if scanner.matches(range, "e") { return .error }
        if scanner.matches(range, "d") { return .isoDate }
        return .number
    }

    private mutating func collectValue(_ scanner: inout XMLByteScanner, unescapingOOXML: Bool) -> CellValue? {
        var direct: Range<Int>?
        var pieces = 0
        valueScratch.removeAll(keepingCapacity: true)
        while true {
            switch scanner.next() {
            case .text(let range):
                pieces += 1
                if pieces == 1, !XMLTextDecoder.needsDecoding(scanner.bytes, range, unescapingOOXML: unescapingOOXML) {
                    direct = range
                    continue
                }
                flush(scanner, &direct)
                XMLTextDecoder.append(scanner.bytes, range, to: &valueScratch, unescapingOOXML: unescapingOOXML)
            case .characterData(let range):
                pieces += 1
                flush(scanner, &direct)
                valueScratch.append(contentsOf: UnsafeBufferPointer(rebasing: scanner.bytes[range]))
            case .endTag:
                if let direct { return .direct(direct) }
                return .decoded
            case .startTag(let name, _, let isSelfClosing):
                if !isSelfClosing, !scanner.skipElement(named: name) { return nil }
            case .markup:
                continue
            case .incomplete, .end:
                return nil
            }
        }
    }

    private mutating func flush(_ scanner: XMLByteScanner, _ direct: inout Range<Int>?) {
        guard let range = direct else { return }
        valueScratch.append(contentsOf: UnsafeBufferPointer(rebasing: scanner.bytes[range]))
        direct = nil
    }

    private mutating func storeInlineText(at position: (row: Int, column: Int)?) {
        guard let position else { return }
        let payload = inlineScratch.withUnsafeBufferPointer { arena.append($0) }
        append(position, kind: XLSXStoredCell.inlineText, payload: payload)
    }

    private mutating func store(
        _ scanner: XMLByteScanner,
        position: (row: Int, column: Int)?,
        type: CellType,
        style: Int,
        value: CellValue
    ) {
        guard let position else { return }
        switch value {
        case .none:
            return
        case .direct(let range):
            store(UnsafeBufferPointer(rebasing: scanner.bytes[range]), at: position, type: type, style: style)
        case .decoded:
            let bytes = valueScratch
            bytes.withUnsafeBufferPointer { store($0, at: position, type: type, style: style) }
        }
    }

    private mutating func store(_ text: UnsafeBufferPointer<UInt8>, at position: (row: Int, column: Int), type: CellType, style: Int) {
        guard !text.isEmpty || type == .formulaString || type == .inlineString else { return }
        switch type {
        case .sharedString:
            guard let index = XLSXDecimal.parse(text), index.scale == 0, index.mantissa >= 0,
                  index.mantissa < Int64(sharedStringCount) else {
                append(position, kind: XLSXStoredCell.inlineText, payload: arena.append(text))
                return
            }
            append(position, kind: XLSXStoredCell.sharedString, payload: UInt64(index.mantissa))
        case .inlineString, .formulaString:
            append(position, kind: XLSXStoredCell.inlineText, payload: arena.append(text))
        case .boolean:
            let isTrue = text.count == 1 ? text[0] == 0x31 : text.elementsEqual("true".utf8)
            append(position, kind: isTrue ? XLSXStoredCell.booleanTrue : XLSXStoredCell.booleanFalse, payload: 0)
        case .error:
            append(position, kind: XLSXStoredCell.errorText, payload: arena.append(text))
        case .isoDate:
            append(position, kind: XLSXStoredCell.dateText, payload: arena.append(text))
        case .number:
            storeNumber(text, at: position, style: style)
        }
    }

    private mutating func storeNumber(_ text: UnsafeBufferPointer<UInt8>, at position: (row: Int, column: Int), style: Int) {
        let category = styles.category(ofStyle: style)
        if category != .number, let serial = XLSXDecimal.doubleValue(of: text), dateSystem.holds(serial: serial) {
            append(position, kind: Self.temporalKind(of: category, serial: serial), payload: serial.bitPattern)
            return
        }
        if let decimal = XLSXDecimal.parse(text) {
            append(position, kind: XLSXStoredCell.decimalBase + UInt8(decimal.scale), payload: UInt64(bitPattern: decimal.mantissa))
            return
        }
        let kind = TabularNumberGrammar.shape(of: text) == nil ? XLSXStoredCell.inlineText : XLSXStoredCell.numberText
        append(position, kind: kind, payload: arena.append(text))
    }

    private static func temporalKind(of category: XLSXNumberFormatCategory, serial: Double) -> UInt8 {
        switch category {
        case .duration:
            return XLSXStoredCell.durationSerial
        case .time where serial < 1:
            return XLSXStoredCell.timeSerial
        case .number, .date, .time:
            return XLSXStoredCell.dateSerial
        }
    }

    private mutating func append(_ position: (row: Int, column: Int), kind: UInt8, payload: UInt64) {
        let column = position.column
        if column >= builders.count {
            builders.append(contentsOf: repeatElement(XLSXColumnBuilder(), count: column + 1 - builders.count))
        }
        builders[column].append(row: position.row, kind: kind, payload: payload)
    }
}
