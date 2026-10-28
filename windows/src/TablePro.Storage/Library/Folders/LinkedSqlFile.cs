using System.Security.Cryptography;
using System.Text;

namespace TablePro.Storage.Library.Folders;

/// <summary>A <c>.sql</c> file found in a linked folder, with what its header says about it.</summary>
public sealed record LinkedSqlFile
{
    public required Guid FolderId { get; init; }

    public required string FullPath { get; init; }

    /// <summary>The path inside the linked folder with forward slashes, which is also how git names it under the folder.</summary>
    public required string RelativePath { get; init; }

    /// <summary>The header's <c>@name</c>, or the file name without its extension.</summary>
    public required string Name { get; init; }

    public string? Keyword { get; init; }

    public string? Description { get; init; }

    public DateTimeOffset Modified { get; init; }

    public long Size { get; init; }

    public string EncodingName { get; init; } = "utf-8";

    public Guid Id => StableId(FolderId, RelativePath);

    public string FileName => Path.GetFileName(FullPath);

    /// <summary>The folders between the linked folder and the file, empty for a file at the top.</summary>
    public string Directory => RelativePath.LastIndexOf('/') is var slash and > 0 ? RelativePath[..slash] : string.Empty;

    /// <summary>
    /// The same id the macOS app derives: a version 5 style UUID from SHA-256 of the folder id and relative path, so a
    /// file keeps its id across scans and launches.
    /// </summary>
    public static Guid StableId(Guid folderId, string relativePath)
    {
        var key = folderId.ToString("D").ToUpperInvariant() + "|" + relativePath;
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(Encoding.UTF8.GetBytes(key), hash);
        var bytes = hash[..16];
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x50);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes, bigEndian: true);
    }
}
