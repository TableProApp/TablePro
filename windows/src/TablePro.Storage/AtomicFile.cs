using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;

namespace TablePro.Storage;

/// <summary>
/// Writes a file so a crash or power loss leaves either the old content or the new, never a torn file:
/// the bytes go to a sibling temporary file, reach the disk, and then replace the target with one rename.
/// </summary>
internal static class AtomicFile
{
    private const int ReplaceAttempts = 6;

    // Hand-edited settings files get comments and trailing commas; refusing them would throw the user's edits away.
    private static readonly JsonDocumentOptions DocumentOptions = new()
    {
        AllowTrailingCommas = true,
        CommentHandling = JsonCommentHandling.Skip,
    };

    public static async Task WriteAsync(string path, Func<Stream, CancellationToken, Task> write, CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        var temp = Path.Combine(directory, string.Create(CultureInfo.InvariantCulture, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp"));
        try
        {
            var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 16 * 1024, FileOptions.Asynchronous);
            await using (stream)
            {
                await write(stream, cancellationToken);
                await stream.FlushAsync(cancellationToken);

                // Without this the rename can reach the disk before the data, which is the torn file we are avoiding.
                stream.Flush(flushToDisk: true);
            }

            await ReplaceAsync(temp, path, cancellationToken);
        }
        catch
        {
            TryDelete(temp);
            throw;
        }
    }

    public static Task WriteJsonAsync<T>(string path, T value, JsonTypeInfo<T> typeInfo, CancellationToken cancellationToken) =>
        WriteAsync(path, (stream, ct) => JsonSerializer.SerializeAsync(stream, value, typeInfo, ct), cancellationToken);

    /// <summary>
    /// Reads a JSON document. A missing file is null. A file that no longer parses is moved aside as
    /// <c>name.corrupt-timestamp</c> and read as null, so the app starts and the user's data stays recoverable.
    /// </summary>
    /// <param name="path">The file to read.</param>
    /// <param name="typeInfo">The document's generated metadata.</param>
    /// <param name="prepare">Rewrites the parsed object before it is bound, typically to restore defaults with <see cref="JsonDefaults"/>.</param>
    /// <param name="cancellationToken">Stops the read.</param>
    public static async Task<T?> ReadJsonAsync<T>(string path, JsonTypeInfo<T> typeInfo, Func<JsonObject, JsonObject>? prepare, CancellationToken cancellationToken)
        where T : class
    {
        FileStream stream;
        try
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 16 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }

        try
        {
            JsonNode? node;
            await using (stream)
            {
                node = await JsonNode.ParseAsync(stream, nodeOptions: null, DocumentOptions, cancellationToken);
            }

            if (node is not JsonObject root)
            {
                throw new JsonException("The document is not a JSON object.");
            }

            return (prepare is null ? root : prepare(root)).Deserialize(typeInfo);
        }
        catch (JsonException)
        {
            Quarantine(path);
            return null;
        }
    }

    private static async Task ReplaceAsync(string source, string destination, CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                // MoveFileEx with MOVEFILE_REPLACE_EXISTING: a rename within one volume, so readers see old or new.
                File.Move(source, destination, overwrite: true);
                return;
            }
            catch (Exception ex) when (attempt < ReplaceAttempts && ex is IOException or UnauthorizedAccessException)
            {
                // Antivirus scanners and the search indexer briefly hold files open after every write.
                await Task.Delay(15 * attempt, cancellationToken);
            }
        }
    }

    private static void Quarantine(string path)
    {
        var stamp = DateTime.UtcNow.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture);
        try
        {
            File.Move(path, path + ".corrupt-" + stamp, overwrite: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
