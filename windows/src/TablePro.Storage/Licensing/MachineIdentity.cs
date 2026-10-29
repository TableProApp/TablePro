using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace TablePro.Storage.Licensing;

/// <summary>Who this machine is to the license server: a stable id a seat is bound to, and a name a person recognizes.</summary>
public interface IMachineIdentity
{
    /// <summary>A SHA-256 hex digest, so the hardware id itself never leaves the machine.</summary>
    string MachineId { get; }

    string MachineName { get; }
}

/// <summary>A fixed identity, for tests.</summary>
public sealed record FixedMachineIdentity(string MachineId, string MachineName) : IMachineIdentity;

/// <summary>
/// The machine's identity as the macOS app derives it from the hardware UUID. Windows' counterpart is the SMBIOS
/// system UUID, which survives reinstalling Windows as the Mac's does macOS. Boards that leave it blank fall back to
/// the Windows installation's MachineGuid, and failing that to a random id kept in the data folder.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed partial class WindowsMachineIdentity(AppPaths paths) : IMachineIdentity
{
    // 'RSMB', the raw SMBIOS firmware table provider.
    private const uint RawSmbiosProvider = 0x52534D42;

    private readonly Lazy<string> _machineId = new(() => Hash(SmbiosUuid() ?? WindowsMachineGuid() ?? StoredFallback(paths)));

    public string MachineId => _machineId.Value;

    /// <summary>The case-kept DNS host name, which is what Settings > System shows as the device name.</summary>
    public string MachineName
    {
        get
        {
            try
            {
                return System.Net.Dns.GetHostName();
            }
            catch (System.Net.Sockets.SocketException)
            {
                return Environment.MachineName;
            }
        }
    }

    internal static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static unsafe string? SmbiosUuid()
    {
        var size = NativeMethods.GetSystemFirmwareTable(RawSmbiosProvider, 0, null, 0);
        if (size == 0)
        {
            return null;
        }

        var buffer = new byte[size];
        fixed (byte* pointer = buffer)
        {
            if (NativeMethods.GetSystemFirmwareTable(RawSmbiosProvider, 0, pointer, size) != size)
            {
                return null;
            }
        }

        return SmbiosTable.SystemUuid(buffer)?.ToString("D").ToUpperInvariant();
    }

    private static string? WindowsMachineGuid()
    {
        using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
        return key?.GetValue("MachineGuid") is string { Length: > 0 } guid ? guid.ToUpperInvariant() : null;
    }

    private static string StoredFallback(AppPaths paths)
    {
        var file = Path.Combine(paths.Root, "machine_id");
        try
        {
            var stored = File.ReadAllText(file).Trim();
            if (stored.Length > 0)
            {
                return stored;
            }
        }
        catch (IOException)
        {
        }

        var created = Guid.NewGuid().ToString("D").ToUpperInvariant();
        File.WriteAllText(file, created);
        return created;
    }

    private static unsafe partial class NativeMethods
    {
        [LibraryImport("kernel32.dll", SetLastError = true)]
        public static partial uint GetSystemFirmwareTable(uint firmwareTableProviderSignature, uint firmwareTableId, byte* firmwareTableBuffer, uint bufferSize);
    }
}

/// <summary>Reads the system UUID out of the raw SMBIOS table Windows returns, the RawSMBIOSData structure.</summary>
public static class SmbiosTable
{
    private const int HeaderLength = 8;
    private const byte SystemInformation = 1;
    private const byte EndOfTable = 127;

    // The UUID sits at offset 8 of the System Information structure, which is 0x19 bytes long from SMBIOS 2.1 on.
    private const int UuidOffset = 8;
    private const int MinimumSystemInformationLength = 0x19;

    /// <returns>The UUID, or null when the table has none or it is all zeros or all ones, which SMBIOS uses for unset.</returns>
    public static Guid? SystemUuid(ReadOnlySpan<byte> raw)
    {
        if (raw.Length < HeaderLength)
        {
            return null;
        }

        var end = Math.Min(raw.Length, HeaderLength + (int)Math.Min(BinaryPrimitives.ReadUInt32LittleEndian(raw[4..]), int.MaxValue - HeaderLength));
        var position = HeaderLength;
        while (position + 4 <= end)
        {
            var type = raw[position];
            int length = raw[position + 1];
            if (length < 4 || position + length > end)
            {
                return null;
            }

            if (type == SystemInformation && length >= MinimumSystemInformationLength)
            {
                var uuid = raw.Slice(position + UuidOffset, 16);
                return uuid.IndexOfAnyExcept((byte)0) < 0 || uuid.IndexOfAnyExcept((byte)0xFF) < 0 ? null : new Guid(uuid);
            }

            if (type == EndOfTable)
            {
                return null;
            }

            // Each structure is followed by its strings, ended by two zero bytes.
            var strings = position + length;
            while (strings + 1 < end && (raw[strings] != 0 || raw[strings + 1] != 0))
            {
                strings++;
            }

            position = strings + 2;
        }

        return null;
    }
}
