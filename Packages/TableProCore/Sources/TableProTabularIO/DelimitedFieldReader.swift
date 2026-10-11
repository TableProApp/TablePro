import Foundation

public struct DelimitedFieldReader: Sendable {
    public let dialect: DelimitedDialect

    public init(dialect: DelimitedDialect) {
        self.dialect = dialect
    }

    public func forEachField(
        in base: UnsafePointer<UInt8>,
        range: Range<Int>,
        scratch: inout [UInt8],
        _ body: (Int, UnsafeBufferPointer<UInt8>) -> Bool
    ) {
        let end = range.upperBound
        var index = range.lowerBound
        var column = 0
        while true {
            let next = readField(in: base, from: index, end: end, scratch: &scratch) { content in
                body(column, content)
            }
            guard let resume = next.resume, next.shouldContinue else { return }
            index = resume
            column += 1
        }
    }

    public func field(
        in base: UnsafePointer<UInt8>,
        range: Range<Int>,
        column target: Int,
        scratch: inout [UInt8],
        _ body: (UnsafeBufferPointer<UInt8>?) -> Void
    ) {
        var delivered = false
        forEachField(in: base, range: range, scratch: &scratch) { column, content in
            guard column == target else { return column < target }
            body(content)
            delivered = true
            return false
        }
        if !delivered {
            body(nil)
        }
    }

    public func fieldCount(in base: UnsafePointer<UInt8>, range: Range<Int>, scratch: inout [UInt8]) -> Int {
        var count = 0
        forEachField(in: base, range: range, scratch: &scratch) { _, _ in
            count += 1
            return true
        }
        return count
    }

    public func fields(in base: UnsafePointer<UInt8>, range: Range<Int>) -> [String] {
        var scratch: [UInt8] = []
        var result: [String] = []
        forEachField(in: base, range: range, scratch: &scratch) { _, content in
            result.append(TabularTextCodec.string(from: content, encoding: dialect.encoding.readsInPlace
                ? dialect.encoding
                : .utf8))
            return true
        }
        return result
    }

    private struct FieldEnd {
        let resume: Int?
        let shouldContinue: Bool
    }

    private func readField(
        in base: UnsafePointer<UInt8>,
        from start: Int,
        end: Int,
        scratch: inout [UInt8],
        _ deliver: (UnsafeBufferPointer<UInt8>) -> Bool
    ) -> FieldEnd {
        let delimiter = dialect.delimiter
        let quote = dialect.quote
        guard start < end, base[start] == quote else {
            var index = start
            while index < end {
                let byte = base[index]
                if byte == delimiter || byte == 0x0A || byte == 0x0D { break }
                index += 1
            }
            let keepGoing = deliver(UnsafeBufferPointer(start: base + start, count: index - start))
            let resumes = index < end && base[index] == delimiter
            return FieldEnd(resume: resumes ? index + 1 : nil, shouldContinue: keepGoing)
        }
        return readQuotedField(in: base, from: start, end: end, scratch: &scratch, deliver)
    }

    private func readQuotedField(
        in base: UnsafePointer<UInt8>,
        from start: Int,
        end: Int,
        scratch: inout [UInt8],
        _ deliver: (UnsafeBufferPointer<UInt8>) -> Bool
    ) -> FieldEnd {
        let delimiter = dialect.delimiter
        let quote = dialect.quote
        let escape = dialect.escape
        let escapeDiffers = escape != quote
        scratch.removeAll(keepingCapacity: true)
        var insideQuotes = true
        var index = start + 1
        while index < end {
            let byte = base[index]
            if insideQuotes {
                if escapeDiffers, byte == escape, index + 1 < end {
                    scratch.append(base[index + 1])
                    index += 2
                    continue
                }
                if byte == quote {
                    if !escapeDiffers, index + 1 < end, base[index + 1] == quote {
                        scratch.append(quote)
                        index += 2
                        continue
                    }
                    insideQuotes = false
                    index += 1
                    continue
                }
                scratch.append(byte)
                index += 1
                continue
            }
            if byte == quote, scratch.isEmpty {
                insideQuotes = true
                index += 1
                continue
            }
            if byte == delimiter || byte == 0x0A || byte == 0x0D { break }
            scratch.append(byte)
            index += 1
        }
        let keepGoing = scratch.withUnsafeBufferPointer { deliver($0) }
        let resumes = index < end && base[index] == delimiter
        return FieldEnd(resume: resumes ? index + 1 : nil, shouldContinue: keepGoing)
    }
}
