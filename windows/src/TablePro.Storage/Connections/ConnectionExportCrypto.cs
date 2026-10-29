using System.Security.Cryptography;
using System.Text;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Connections;

/// <summary>
/// The macOS app's encrypted export envelope (<c>ConnectionExportCrypto</c>), byte for byte:
/// <c>"TPRO"</c>, a version byte, a 32-byte salt, a 12-byte nonce, the AES-256-GCM ciphertext and its 16-byte tag.
/// The key is PBKDF2-HMAC-SHA256 of the UTF-8 passphrase with 600,000 iterations.
/// </summary>
internal static class ConnectionExportCrypto
{
    private const byte CurrentVersion = 1;
    private const int SaltLength = 32;
    private const int NonceLength = 12;
    private const int TagLength = 16;
    private const int KeyLength = 32;
    private const int Iterations = 600_000;
    private const int HeaderLength = 4 + 1 + SaltLength + NonceLength;

    private static ReadOnlySpan<byte> Magic => "TPRO"u8;

    public static bool IsEncrypted(ReadOnlySpan<byte> data) => data.Length > HeaderLength && data[..4].SequenceEqual(Magic);

    public static byte[] Encrypt(ReadOnlySpan<byte> plaintext, string passphrase)
    {
        ArgumentException.ThrowIfNullOrEmpty(passphrase);
        var result = new byte[HeaderLength + plaintext.Length + TagLength];
        var span = result.AsSpan();
        Magic.CopyTo(span);
        span[4] = CurrentVersion;
        var salt = span.Slice(5, SaltLength);
        var nonce = span.Slice(5 + SaltLength, NonceLength);
        RandomNumberGenerator.Fill(salt);
        RandomNumberGenerator.Fill(nonce);

        var key = DeriveKey(passphrase, salt);
        try
        {
            using var aes = new AesGcm(key, TagLength);
            aes.Encrypt(nonce, plaintext, span.Slice(HeaderLength, plaintext.Length), span[(HeaderLength + plaintext.Length)..]);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }

        return result;
    }

    /// <exception cref="InvalidDataException">The data is not an envelope, is cut short, or needs a newer version.</exception>
    /// <exception cref="ConnectionExportPassphraseException">The passphrase does not open it.</exception>
    public static byte[] Decrypt(ReadOnlySpan<byte> data, string passphrase)
    {
        ArgumentNullException.ThrowIfNull(passphrase);
        if (!IsEncrypted(data) || data.Length <= HeaderLength + TagLength)
        {
            throw new InvalidDataException(StorageStrings.Get("Connections/EncryptedCorrupt"));
        }

        var version = data[4];
        if (version > CurrentVersion)
        {
            throw new InvalidDataException(StorageStrings.Format("Connections/EncryptionVersionUnsupported", version));
        }

        var salt = data.Slice(5, SaltLength);
        var nonce = data.Slice(5 + SaltLength, NonceLength);
        var cipher = data[HeaderLength..^TagLength];
        var tag = data[^TagLength..];
        var plaintext = new byte[cipher.Length];
        var key = DeriveKey(passphrase, salt);
        try
        {
            using var aes = new AesGcm(key, TagLength);
            aes.Decrypt(nonce, cipher, tag, plaintext);
            return plaintext;
        }
        catch (AuthenticationTagMismatchException ex)
        {
            throw new ConnectionExportPassphraseException(StorageStrings.Get("Connections/IncorrectPassphrase"), ex);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
    }

    private static byte[] DeriveKey(string passphrase, ReadOnlySpan<byte> salt) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase), salt, Iterations, HashAlgorithmName.SHA256, KeyLength);
}

/// <summary>An encrypted export needs a passphrase, or the one given does not open it.</summary>
public sealed class ConnectionExportPassphraseException : IOException
{
    public ConnectionExportPassphraseException()
        : base(StorageStrings.Get("Connections/PassphraseRequired"))
    {
    }

    public ConnectionExportPassphraseException(string message)
        : base(message)
    {
    }

    public ConnectionExportPassphraseException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <summary>True when no passphrase was given, false when the one given was wrong.</summary>
    public bool PassphraseMissing { get; init; }
}
