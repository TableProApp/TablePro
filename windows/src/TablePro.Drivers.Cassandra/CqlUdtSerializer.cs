using Cassandra;
using Cassandra.Serialization;
using TablePro.Drivers.Cassandra.Localization;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// Reads every user-defined type into a <see cref="CqlUdtValue"/>. The driver maps a UDT only onto a CLR class
/// registered for it, and a database client has no such classes, so without this a UDT column arrives as raw bytes.
/// </summary>
internal sealed class CqlUdtSerializer : UdtSerializer
{
    public override object Deserialize(ushort protocolVersion, byte[] buffer, int offset, int length, IColumnInfo typeInfo) =>
        CqlValueDecoder.DecodeUdt(buffer.AsSpan(offset, length), (UdtColumnInfo)typeInfo);

    public override byte[] Serialize(ushort protocolVersion, object value) =>
        throw new NotSupportedException(CassandraStrings.Get("Cassandra/UdtAsJson"));

    protected override Type GetClrType(IColumnInfo typeInfo) => typeof(CqlUdtValue);
}
