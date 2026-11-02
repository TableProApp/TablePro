using System.Diagnostics.CodeAnalysis;

namespace TablePro.Interop;

/// <summary>
/// What a column or a cell holds. The values are the bytes a <see cref="ResultWindow"/> carries, and a
/// cell's kind says what its raw value means; core/crates/ffi/src/results/value_kind.rs has each one.
/// </summary>
[SuppressMessage("Naming", "CA1720", Justification = "The names are SQL value kinds, not .NET types.")]
public enum ValueKind : byte
{
    Other = 0,
    Bool = 1,
    Integer = 2,
    UnsignedInteger = 3,
    WideInteger = 4,
    Float = 5,
    Decimal = 6,
    Text = 7,
    Bytes = 8,
    Uuid = 9,
    Json = 10,
    Date = 11,
    Time = 12,
    TimeWithOffset = 13,
    Timestamp = 14,
    TimestampWithOffset = 15,
    Interval = 16,
    Bits = 17,
    Array = 18,
    Network = 19,
    Spatial = 20,
    Xml = 21,
    Undecodable = 22,
}
