using System.Text;
using System.Text.RegularExpressions;

namespace TablePro.App.Model;

// What one launch asks the app to open: links (tablepro:// or a database URL) and files, each in the order given.
public sealed partial record ActivationRequest(IReadOnlyList<string> Links, IReadOnlyList<string> Files)
{
    public static ActivationRequest None { get; } = new([], []);

    public bool IsEmpty => Links.Count == 0 && Files.Count == 0;

    // A word with a URL scheme is a link, an option is left for the CLI, and any other word names a file.
    public static ActivationRequest FromArguments(IEnumerable<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var links = new List<string>();
        var files = new List<string>();
        foreach (var raw in arguments)
        {
            var argument = raw.Trim().Trim('"').Trim();
            if (argument.Length == 0 || argument.StartsWith('-'))
            {
                continue;
            }

            if (FileUriPath(argument) is { } local)
            {
                AddFile(files, local);
            }
            else if (IsLink(argument))
            {
                links.Add(argument);
            }
            else
            {
                AddFile(files, argument);
            }
        }

        return new ActivationRequest(links, files);
    }

    // Relative file paths made whole, since a second launch hands them to an app in another folder; null when none is.
    public static IReadOnlyList<string>? WholePaths(IReadOnlyList<string> arguments, string directory)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentNullException.ThrowIfNull(directory);
        var changed = false;
        var whole = new List<string>(arguments.Count);
        foreach (var raw in arguments)
        {
            var argument = raw.Trim().Trim('"').Trim();
            if (argument.Length > 0 && !argument.StartsWith('-') && FileUriPath(argument) is null && !IsLink(argument)
                && !Path.IsPathFullyQualified(argument) && FullPath(argument, directory) is { } full)
            {
                whole.Add(full);
                changed = true;
            }
            else
            {
                whole.Add(raw);
            }
        }

        return changed ? whole : null;
    }

    // A launch activation's arguments as one line, which an unpackaged launch starts with the program's own path.
    public static ActivationRequest FromCommandLine(string? line)
    {
        var words = SplitCommandLine(line ?? string.Empty);
        var skip = words.Count > 0 && words[0].EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
        return FromArguments(words.Skip(skip));
    }

    // Explorer hands a packaged app the files it opens with it.
    public static ActivationRequest FromFiles(IEnumerable<string?> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var files = new List<string>();
        foreach (var path in paths)
        {
            if (!string.IsNullOrWhiteSpace(path))
            {
                AddFile(files, path);
            }
        }

        return new ActivationRequest([], files);
    }

    // A scheme of two or more characters before //, so a drive letter never reads as one; jdbc: may wrap it.
    public static bool IsLink(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return text.StartsWith("tablepro:", StringComparison.OrdinalIgnoreCase)
            || UrlStart().IsMatch(text)
            || FileEngineUrlStart().IsMatch(text);
    }

    // As CommandLineToArgvW splits one: quotes group, 2n backslashes before a quote give n, 2n+1 give n and the quote.
    public static IReadOnlyList<string> SplitCommandLine(string line)
    {
        ArgumentNullException.ThrowIfNull(line);
        var words = new List<string>();
        var word = new StringBuilder();
        var inWord = false;
        var quoted = false;
        var index = 0;
        while (index < line.Length)
        {
            var c = line[index];
            if (c == '\\')
            {
                var start = index;
                while (index < line.Length && line[index] == '\\')
                {
                    index++;
                }

                var count = index - start;
                if (index < line.Length && line[index] == '"')
                {
                    word.Append('\\', count / 2);
                    if (count % 2 == 1)
                    {
                        word.Append('"');
                        index++;
                    }
                }
                else
                {
                    word.Append('\\', count);
                }

                inWord = true;
                continue;
            }

            if (c == '"')
            {
                // Two quotes inside a quoted part stand for one quote.
                if (quoted && index + 1 < line.Length && line[index + 1] == '"')
                {
                    word.Append('"');
                    index += 2;
                    continue;
                }

                quoted = !quoted;
                inWord = true;
                index++;
                continue;
            }

            if (!quoted && char.IsWhiteSpace(c))
            {
                if (inWord)
                {
                    words.Add(word.ToString());
                    word.Clear();
                    inWord = false;
                }

                index++;
                continue;
            }

            word.Append(c);
            inWord = true;
            index++;
        }

        if (inWord)
        {
            words.Add(word.ToString());
        }

        return words;
    }

    private static string? FileUriPath(string text) =>
        text.StartsWith("file:", StringComparison.OrdinalIgnoreCase)
        && Uri.TryCreate(text, UriKind.Absolute, out var uri)
        && uri.IsFile
            ? uri.LocalPath
            : null;

    private static string? FullPath(string path, string directory)
    {
        try
        {
            return Path.GetFullPath(path, directory);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    private static void AddFile(List<string> files, string path)
    {
        string full;
        try
        {
            full = Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return;
        }

        if (!files.Contains(full, StringComparer.OrdinalIgnoreCase))
        {
            files.Add(full);
        }
    }

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9+.-]+:(?:[A-Za-z][A-Za-z0-9+.-]*:)?//", RegexOptions.CultureInvariant)]
    private static partial Regex UrlStart();

    // The core also reads a file engine's URL with one slash, as sqlite:/C:/data/app.db.
    [GeneratedRegex("^(?:sqlite3?|duckdb):/", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex FileEngineUrlStart();
}
