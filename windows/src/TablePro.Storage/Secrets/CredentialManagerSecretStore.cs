using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Secrets;

/// <summary>
/// Keeps secrets as generic credentials in Windows Credential Manager, encrypted with the user's logon
/// credentials and readable only by that Windows account.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed partial class CredentialManagerSecretStore : ISecretStore
{
    // CRED_MAX_CREDENTIAL_BLOB_SIZE: five 512-byte pages.
    private const int MaxBlobBytes = 5 * 512;
    private const uint CredTypeGeneric = 1;

    // Local machine persistence keeps the secret off roaming profiles, where it would sync to other machines.
    private const uint CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    private readonly string _userName;

    /// <param name="userName">What Credential Manager shows as the user name of each entry.</param>
    public CredentialManagerSecretStore(string userName = "TablePro")
    {
        _userName = userName;
    }

    public unsafe string? Get(string key)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        if (!NativeMethods.CredRead(key, CredTypeGeneric, 0, out var handle))
        {
            var error = Marshal.GetLastPInvokeError();
            return error == ErrorNotFound ? null : throw new Win32Exception(error, StorageStrings.Format("Credentials/ReadFailed", key));
        }

        try
        {
            var credential = (NativeMethods.Credential*)handle;
            var size = (int)credential->CredentialBlobSize;
            if (size == 0 || credential->CredentialBlob is null)
            {
                return string.Empty;
            }

            var blob = new ReadOnlySpan<byte>(credential->CredentialBlob, size);

            // Entries this app writes are UTF-16; an odd length can only be UTF-8 written by another tool.
            var secret = size % 2 == 0 ? new string(MemoryMarshal.Cast<byte, char>(blob)) : Encoding.UTF8.GetString(blob);
            CryptographicOperations.ZeroMemory(new Span<byte>(credential->CredentialBlob, size));
            return secret;
        }
        finally
        {
            NativeMethods.CredFree(handle);
        }
    }

    public unsafe void Set(string key, string secret)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        ArgumentNullException.ThrowIfNull(secret);
        var byteCount = Encoding.Unicode.GetByteCount(secret);
        if (byteCount > MaxBlobBytes)
        {
            throw new ArgumentException(StorageStrings.Format("Credentials/SecretTooLong", MaxBlobBytes / 2), nameof(secret));
        }

        var bytes = GC.AllocateUninitializedArray<byte>(byteCount, pinned: true);
        try
        {
            Encoding.Unicode.GetBytes(secret, bytes);
            fixed (char* target = key)
            fixed (char* user = _userName)
            fixed (byte* blob = bytes)
            {
                var credential = new NativeMethods.Credential
                {
                    Type = CredTypeGeneric,
                    TargetName = target,
                    CredentialBlobSize = (uint)byteCount,
                    CredentialBlob = blob,
                    Persist = CredPersistLocalMachine,
                    UserName = user,
                };
                if (!NativeMethods.CredWrite(&credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), StorageStrings.Format("Credentials/SaveFailed", key));
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public bool Delete(string key)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        if (NativeMethods.CredDelete(key, CredTypeGeneric, 0))
        {
            return true;
        }

        var error = Marshal.GetLastPInvokeError();
        return error == ErrorNotFound ? false : throw new Win32Exception(error, StorageStrings.Format("Credentials/DeleteFailed", key));
    }

    private static unsafe partial class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct Credential
        {
            public uint Flags;
            public uint Type;
            public char* TargetName;
            public char* Comment;
            // FILETIME is two DWORDs, so it aligns to 4 bytes, not 8.
            public uint LastWrittenLow;
            public uint LastWrittenHigh;
            public uint CredentialBlobSize;
            public byte* CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public nint Attributes;
            public char* TargetAlias;
            public char* UserName;
        }

        [LibraryImport("advapi32.dll", EntryPoint = "CredWriteW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool CredWrite(Credential* credential, uint flags);

        [LibraryImport("advapi32.dll", EntryPoint = "CredReadW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool CredRead(string targetName, uint type, uint flags, out nint credential);

        [LibraryImport("advapi32.dll", EntryPoint = "CredDeleteW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool CredDelete(string targetName, uint type, uint flags);

        [LibraryImport("advapi32.dll", EntryPoint = "CredFree")]
        public static partial void CredFree(nint buffer);
    }
}
