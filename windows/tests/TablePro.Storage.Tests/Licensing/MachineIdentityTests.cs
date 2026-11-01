using System.Buffers.Binary;
using TablePro.Storage.Licensing;

namespace TablePro.Storage.Tests.Licensing;

public sealed class MachineIdentityTests
{
    private static readonly Guid Uuid = Guid.Parse("4c4c4544-0042-3510-8052-b7c04f564432");

    /// <summary>A RawSMBIOSData buffer: the 8-byte header, a BIOS structure with strings, a System Information structure, the end marker.</summary>
    private static byte[] Table(ReadOnlySpan<byte> uuid, byte systemLength = 0x1B)
    {
        var body = new List<byte>();

        // Type 0 (BIOS), length 4, handle 0, followed by two strings.
        body.AddRange([0, 4, 0, 0]);
        body.AddRange("Vendor\0Version\0\0"u8.ToArray());

        // Type 1 (System Information).
        var system = new byte[systemLength];
        system[0] = 1;
        system[1] = systemLength;
        uuid[..Math.Min(uuid.Length, Math.Max(0, systemLength - 8))].CopyTo(system.AsSpan(8));
        body.AddRange(system);
        body.AddRange("Maker\0\0"u8.ToArray());

        // Type 127 (end of table), no strings.
        body.AddRange([127, 4, 0, 0, 0, 0]);

        var raw = new byte[8 + body.Count];
        raw[1] = 3;
        BinaryPrimitives.WriteUInt32LittleEndian(raw.AsSpan(4), (uint)body.Count);
        body.CopyTo(raw, 8);
        return raw;
    }

    [Fact]
    public void TheSystemUuidIsReadFromTheSystemInformationStructure() =>
        Assert.Equal(Uuid, SmbiosTable.SystemUuid(Table(Uuid.ToByteArray())));

    [Fact]
    public void AnUnsetUuidIsNoUuid()
    {
        Assert.Null(SmbiosTable.SystemUuid(Table(new byte[16])));
        Assert.Null(SmbiosTable.SystemUuid(Table(Enumerable.Repeat((byte)0xFF, 16).ToArray())));
    }

    [Fact]
    public void ATableWithoutSystemInformationOrTooShortHasNoUuid()
    {
        Assert.Null(SmbiosTable.SystemUuid(Table(Uuid.ToByteArray(), systemLength: 0x08 + 0x08)));
        Assert.Null(SmbiosTable.SystemUuid([1, 2, 3]));
        Assert.Null(SmbiosTable.SystemUuid(Table(Uuid.ToByteArray()).AsSpan(0, 20)));
    }

    [Fact]
    public void ThisMachinesIdIsAStableSha256Digest()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Skip("The SMBIOS table is read through Windows.");
            return;
        }

        using var temp = new TempDirectory();
        var first = new WindowsMachineIdentity(temp.Paths);
        var second = new WindowsMachineIdentity(temp.Paths);

        Assert.Matches("^[0-9a-f]{64}$", first.MachineId);
        Assert.Equal(first.MachineId, second.MachineId);
        Assert.False(string.IsNullOrWhiteSpace(first.MachineName));
    }
}
