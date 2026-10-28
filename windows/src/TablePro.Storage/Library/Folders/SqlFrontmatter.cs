using System.Text;

namespace TablePro.Storage.Library.Folders;

/// <summary>The header keys the app reads and writes, in the order it writes them.</summary>
public enum SqlFrontmatterKey
{
    Name,
    Keyword,
    Description,
}

/// <summary>What a linked file's header says about it.</summary>
public sealed record SqlFileMetadata(string? Name = null, string? Keyword = null, string? Description = null)
{
    public string? Value(SqlFrontmatterKey key) => key switch
    {
        SqlFrontmatterKey.Name => Name,
        SqlFrontmatterKey.Keyword => Keyword,
        _ => Description,
    };
}

/// <summary>One <c>-- @key: value</c> line, with its own text and line ending so a rewrite can keep it byte for byte.</summary>
public sealed record SqlFrontmatterLine(string Text, string Terminator, string Key, string Value)
{
    public SqlFrontmatterKey? OwnedKey => Key switch
    {
        "name" => SqlFrontmatterKey.Name,
        "keyword" => SqlFrontmatterKey.Keyword,
        "description" => SqlFrontmatterKey.Description,
        _ => null,
    };
}

public sealed record SqlFrontmatterDocument(string ByteOrderMark, IReadOnlyList<SqlFrontmatterLine> Header, string Body);

/// <summary>
/// The comment header the macOS app reads from linked <c>.sql</c> files: leading <c>-- @name:</c>,
/// <c>-- @keyword:</c> and <c>-- @description:</c> lines. Keys the app does not own, such as a formatter directive,
/// are kept where they are, so the same folder can be shared between both apps and other tools.
/// </summary>
public static class SqlFrontmatter
{
    private const char ByteOrderMark = '﻿';
    private const string DefaultLineBreak = "\n";

    public static SqlFileMetadata Parse(string content)
    {
        string? name = null;
        string? keyword = null;
        string? description = null;
        foreach (var line in Split(content).Header)
        {
            switch (line.OwnedKey)
            {
                case SqlFrontmatterKey.Name:
                    name = line.Value;
                    break;
                case SqlFrontmatterKey.Keyword:
                    keyword = line.Value.Length == 0 ? null : line.Value;
                    break;
                case SqlFrontmatterKey.Description:
                    description = line.Value;
                    break;
            }
        }

        return new SqlFileMetadata(name, keyword, description);
    }

    public static SqlFrontmatterDocument Split(string content)
    {
        var hasBom = content.Length > 0 && content[0] == ByteOrderMark;
        var text = hasBom ? content[1..] : content;
        var header = new List<SqlFrontmatterLine>();
        var lineStart = 0;
        while (lineStart < text.Length)
        {
            var lineEnd = text.IndexOfAny(['\r', '\n'], lineStart);
            if (lineEnd < 0)
            {
                lineEnd = text.Length;
            }

            var line = text[lineStart..lineEnd];
            if (ParseLine(line.Trim(' ', '\t')) is not { } entry)
            {
                break;
            }

            var next = StartOfNextLine(text, lineEnd);
            header.Add(new SqlFrontmatterLine(line, text[lineEnd..next], entry.Key, entry.Value));
            lineStart = next;
        }

        return new SqlFrontmatterDocument(hasBom ? ByteOrderMark.ToString() : string.Empty, header, text[lineStart..]);
    }

    /// <summary>
    /// Writes <paramref name="metadata"/> into the header of <paramref name="content"/>. An unchanged value keeps its
    /// line byte for byte, a cleared one loses its line, a new one goes beside the owned keys in canonical order, and
    /// the file's own line ending is used for new lines.
    /// </summary>
    public static string Rewrite(string content, SqlFileMetadata metadata)
    {
        ArgumentNullException.ThrowIfNull(metadata);
        var document = Split(content);
        var lineBreak = DetectedLineBreak(document);
        var output = new List<(string Text, string Terminator, SqlFrontmatterKey? Key)>();
        var written = new HashSet<SqlFrontmatterKey>();

        foreach (var line in document.Header)
        {
            if (line.OwnedKey is not { } key)
            {
                output.Add((line.Text, line.Terminator, null));
                continue;
            }

            if (written.Contains(key) || HeaderValue(metadata.Value(key)) is not { } value)
            {
                continue;
            }

            written.Add(key);
            output.Add((line.Value == value ? line.Text : Rendered(key, value), line.Terminator, key));
        }

        foreach (var key in Enum.GetValues<SqlFrontmatterKey>())
        {
            if (written.Contains(key) || HeaderValue(metadata.Value(key)) is not { } value)
            {
                continue;
            }

            output.Insert(InsertionIndex(key, output), (Rendered(key, value), lineBreak, key));
        }

        var createdHeader = document.Header.Count == 0 && output.Count > 0;
        var separator = createdHeader && document.Body.Length > 0 && document.Body[0] is not ('\r' or '\n') ? lineBreak : string.Empty;
        var builder = new StringBuilder(document.ByteOrderMark);
        for (var i = 0; i < output.Count; i++)
        {
            builder.Append(output[i].Text);
            builder.Append(output[i].Terminator.Length == 0 && i < output.Count - 1 ? lineBreak : output[i].Terminator);
        }

        return builder.Append(separator).Append(document.Body).ToString();
    }

    private static int InsertionIndex(SqlFrontmatterKey key, List<(string Text, string Terminator, SqlFrontmatterKey? Key)> lines)
    {
        var preceding = lines.FindLastIndex(l => l.Key is { } other && other < key);
        if (preceding >= 0)
        {
            return preceding + 1;
        }

        var firstOwned = lines.FindIndex(l => l.Key is not null);
        return firstOwned >= 0 ? firstOwned : 0;
    }

    /// <summary>A header value on one line, so a multi-line description can never spill into the SQL.</summary>
    private static string? HeaderValue(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var single = string.Join(' ', value.Split(['\r', '\n']).Select(p => p.Trim()).Where(p => p.Length > 0));
        return single.Length == 0 ? null : single;
    }

    private static string Rendered(SqlFrontmatterKey key, string value) =>
        "-- @" + key.ToString().ToLowerInvariant() + ": " + value;

    private static string DetectedLineBreak(SqlFrontmatterDocument document)
    {
        if (document.Header.Select(l => l.Terminator).FirstOrDefault(t => t.Length > 0) is { } terminator)
        {
            return terminator;
        }

        var index = document.Body.IndexOfAny(['\r', '\n']);
        if (index < 0)
        {
            return DefaultLineBreak;
        }

        return document.Body[index] == '\r' && index + 1 < document.Body.Length && document.Body[index + 1] == '\n'
            ? "\r\n"
            : document.Body[index].ToString();
    }

    private static int StartOfNextLine(string text, int lineEnd)
    {
        if (lineEnd >= text.Length)
        {
            return lineEnd;
        }

        if (text[lineEnd] != '\r')
        {
            return lineEnd + 1;
        }

        return lineEnd + 1 < text.Length && text[lineEnd + 1] == '\n' ? lineEnd + 2 : lineEnd + 1;
    }

    private static (string Key, string Value)? ParseLine(string line)
    {
        if (!line.StartsWith("--", StringComparison.Ordinal))
        {
            return null;
        }

        var rest = line.AsSpan(2).TrimStart([' ', '\t']);
        if (rest.Length == 0 || rest[0] != '@')
        {
            return null;
        }

        rest = rest[1..];
        var colon = rest.IndexOf(':');
        if (colon < 0)
        {
            return null;
        }

        var key = rest[..colon].Trim([' ', '\t']).ToString().ToLowerInvariant();
        var value = rest[(colon + 1)..].Trim([' ', '\t']).ToString();
        return key.Length == 0 ? null : (key, value);
    }
}
