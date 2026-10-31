using System.Security.Cryptography;

namespace TablePro.Core.Updates;

/// <summary>Checks a downloaded release against the size and SHA-256 digest the feed published for it.</summary>
public static class UpdateDownload
{
    /// <summary>
    /// Reads the whole stream and compares its length and digest with the asset's. A stream longer than the
    /// published size fails as soon as it passes it, without being read to the end.
    /// </summary>
    public static async Task<bool> MatchesAsync(Stream content, UpdateAsset asset, CancellationToken cancellationToken = default)
    {
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[81920];
        long length = 0;
        int read;
        while ((read = await content.ReadAsync(buffer, cancellationToken)) > 0)
        {
            length += read;
            if (length > asset.Size)
            {
                return false;
            }

            sha.AppendData(buffer, 0, read);
        }

        if (length != asset.Size)
        {
            return false;
        }

        var expected = Convert.FromHexString(asset.Sha256);
        return CryptographicOperations.FixedTimeEquals(sha.GetHashAndReset(), expected);
    }
}
