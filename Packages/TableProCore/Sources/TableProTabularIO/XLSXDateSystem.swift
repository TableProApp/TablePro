import Foundation

public enum XLSXDateSystem: Sendable, Equatable {
    case base1900
    case base1904

    private static let millisecondsPerDay: Int64 = 86_400_000
    private static let unixDayOf18991230 = -25_569
    private static let unixDayOf18991231 = -25_568
    private static let unixDayOf19040101 = -24_107
    private static let phantomLeapDay = 60

    public var serialAfterLastDay: Double {
        switch self {
        case .base1900: return 2_958_466
        case .base1904: return 2_957_004
        }
    }

    public func holds(serial: Double) -> Bool {
        serial.isFinite && serial >= 0 && serial < serialAfterLastDay
    }

    public func isoText(forSerial serial: Double, timeOnly: Bool = false) -> String {
        var output: [UInt8] = []
        appendISOText(forSerial: serial, timeOnly: timeOnly, to: &output)
        return output.withUnsafeBufferPointer { TabularTextCodec.string(from: $0, encoding: .utf8) }
    }

    public func elapsedText(forSerial serial: Double) -> String {
        var output: [UInt8] = []
        appendElapsedText(forSerial: serial, to: &output)
        return output.withUnsafeBufferPointer { TabularTextCodec.string(from: $0, encoding: .utf8) }
    }

    func appendElapsedText(forSerial serial: Double, to output: inout [UInt8]) {
        guard let total = Self.totalMilliseconds(of: serial) else { return }
        if total < 0 { output.append(0x2D) }
        Self.appendTime(total.magnitude, to: &output)
    }

    func appendISOText(forSerial serial: Double, timeOnly: Bool, to output: inout [UInt8]) {
        guard let total = Self.totalMilliseconds(of: serial) else { return }
        let days = Int(Self.floorDivide(total, Self.millisecondsPerDay))
        let milliseconds = total - Int64(days) * Self.millisecondsPerDay
        if timeOnly {
            Self.appendTime(milliseconds.magnitude, to: &output)
            return
        }
        appendDate(days, to: &output)
        guard milliseconds != 0 else { return }
        output.append(0x20)
        Self.appendTime(milliseconds.magnitude, to: &output)
    }

    private static func totalMilliseconds(of serial: Double) -> Int64? {
        Int64(exactly: (serial * Double(millisecondsPerDay)).rounded())
    }

    private func appendDate(_ days: Int, to output: inout [UInt8]) {
        switch self {
        case .base1900 where days == Self.phantomLeapDay:
            Self.appendCivil(year: 1_900, month: 2, day: 29, to: &output)
        case .base1900 where days >= 1 && days < Self.phantomLeapDay:
            Self.appendCivilDay(Self.unixDayOf18991231 + days, to: &output)
        case .base1900:
            Self.appendCivilDay(Self.unixDayOf18991230 + days, to: &output)
        case .base1904:
            Self.appendCivilDay(Self.unixDayOf19040101 + days, to: &output)
        }
    }

    private static func appendCivilDay(_ unixDay: Int, to output: inout [UInt8]) {
        let shifted = unixDay + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        appendCivil(year: year, month: month, day: day, to: &output)
    }

    private static func appendCivil(year: Int, month: Int, day: Int, to output: inout [UInt8]) {
        if year < 0 { output.append(0x2D) }
        appendPadded(abs(year), width: 4, to: &output)
        output.append(0x2D)
        appendPadded(month, width: 2, to: &output)
        output.append(0x2D)
        appendPadded(day, width: 2, to: &output)
    }

    private static func appendTime(_ milliseconds: UInt64, to output: inout [UInt8]) {
        let totalSeconds = Int(milliseconds / 1_000)
        appendPadded(totalSeconds / 3_600, width: 2, to: &output)
        output.append(0x3A)
        appendPadded(totalSeconds / 60 % 60, width: 2, to: &output)
        output.append(0x3A)
        appendPadded(totalSeconds % 60, width: 2, to: &output)
        let fraction = Int(milliseconds % 1_000)
        guard fraction != 0 else { return }
        output.append(0x2E)
        appendPadded(fraction, width: 3, to: &output)
    }

    static func appendPadded(_ value: Int, width: Int, to output: inout [UInt8]) {
        var length = 1
        var probe = value
        while probe >= 10 {
            probe /= 10
            length += 1
        }
        output.append(contentsOf: repeatElement(0x30, count: max(width, length)))
        var remaining = value
        var index = output.count - 1
        repeat {
            output[index] = UInt8(0x30 + remaining % 10)
            remaining /= 10
            index -= 1
        } while remaining > 0
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}
