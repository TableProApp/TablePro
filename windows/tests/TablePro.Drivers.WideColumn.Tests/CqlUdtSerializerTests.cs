using System.Reflection;
using Cassandra;
using Cassandra.Serialization;
using TablePro.Drivers.Cassandra;

namespace TablePro.Drivers.WideColumn.Tests;

public sealed class CqlUdtSerializerTests
{
    // The driver builds its serializer only inside a connected cluster, so this reaches it through reflection. It guards
    // the assumption that a registered UdtSerializer replaces the driver's own, which a driver upgrade could break.
    [Fact]
    public void TheDriverReadsUserTypesThroughTheRegisteredSerializer()
    {
        var definitions = new TypeSerializerDefinitions().Define(new CqlUdtSerializer());
        var serializers = typeof(TypeSerializerDefinitions).GetProperty("Definitions", BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance)!.GetValue(definitions);
        var genericType = typeof(Cluster).Assembly.GetType("Cassandra.Serialization.GenericSerializer")!;
        var generic = Activator.CreateInstance(genericType, BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance, null, [serializers], null)!;
        var deserialize = genericType.GetMethod(
            "Deserialize",
            BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance,
            [typeof(ProtocolVersion), typeof(byte[]), typeof(int), typeof(int), typeof(ColumnTypeCode), typeof(IColumnInfo)])!;

        var udt = new UdtColumnInfo("ks.t");
        udt.Fields.Add(new ColumnDesc { Name = "a", TypeCode = ColumnTypeCode.Int });
        var value = deserialize.Invoke(generic, [ProtocolVersion.V4, new byte[] { 0, 0, 0, 4, 0, 0, 0, 9 }, 0, 8, ColumnTypeCode.Udt, udt]);

        Assert.Equal("{\"a\":9}", CqlCellMapper.ToCell(value));
    }
}
