import Foundation

/// The text of a value read from the bytes db-lib holds for it, for the types whose spelling is fixed: an integer is
/// its decimal digits and a bit is 1 or 0, exactly what `dbconvert` writes for them. Every other type, and a length
/// that is not the type's own, answers nil and goes through `dbconvert`.
public enum MSSQLNativeCellText {
    public static func text(_ bytes: UnsafeRawBufferPointer, type: MSSQLColumnType) -> String? {
        guard let base = bytes.baseAddress else { return nil }
        switch type {
        case .tinyInt where bytes.count == 1:
            return String(base.load(as: UInt8.self))
        case .smallInt where bytes.count == 2:
            return String(base.loadUnaligned(as: Int16.self))
        case .int where bytes.count == 4:
            return String(base.loadUnaligned(as: Int32.self))
        case .bigInt where bytes.count == 8:
            return String(base.loadUnaligned(as: Int64.self))
        case .bit where bytes.count == 1:
            return base.load(as: UInt8.self) == 0 ? "0" : "1"
        default:
            return nil
        }
    }
}
