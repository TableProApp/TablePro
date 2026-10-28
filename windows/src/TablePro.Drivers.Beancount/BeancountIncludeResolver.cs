using System.Text;
using System.Text.RegularExpressions;

namespace TablePro.Drivers.Beancount;

/// <summary>What a ledger is made of, and every path whose change means the projection is stale.</summary>
/// <param name="SourceFiles">The ledger and each file it includes, in the order they were read.</param>
/// <param name="WatchedDirectories">Directories a glob include searched, whose new files would match it.</param>
/// <param name="ReloadDependencies">Source files, watched directories and declared documents, sorted.</param>
/// <param name="Lines">Each source file's physical lines, so the source readers never reopen a file.</param>
internal sealed record BeancountSourceGraph(
    IReadOnlyList<string> SourceFiles,
    IReadOnlyList<string> WatchedDirectories,
    IReadOnlyList<string> ReloadDependencies,
    IReadOnlyDictionary<string, string[]> Lines);

/// <summary>
/// Follows <c>include</c> directives the way Beancount's loader does: relative to the including file, with glob
/// patterns expanded. Paths compare without case, as NTFS does.
/// </summary>
internal sealed class BeancountIncludeResolver
{
    private const int MaximumSymbolicLinkDepth = 32;

    private static readonly StringComparer PathComparer = StringComparer.OrdinalIgnoreCase;
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private readonly HashSet<string> _visited = new(PathComparer);
    private readonly HashSet<string> _activeStack = new(PathComparer);
    private readonly List<string> _sourceFiles = [];
    private readonly Dictionary<string, string[]> _sourceLines = new(PathComparer);
    private readonly HashSet<string> _watchedDirectories = new(PathComparer);
    private readonly List<(string Path, string SourceDirectory)> _documentDeclarations = [];
    private readonly List<string> _documentRootPaths = [];
    private string _mainDirectory = string.Empty;

    public static BeancountSourceGraph Resolve(string ledgerPath) => new BeancountIncludeResolver().ResolveGraph(ledgerPath);

    private BeancountSourceGraph ResolveGraph(string ledgerPath)
    {
        var mainFile = Path.GetFullPath(ledgerPath);
        _mainDirectory = Path.GetDirectoryName(mainFile) ?? mainFile;
        ResolveFile(mainFile);

        var dependencies = new HashSet<string>(_sourceFiles, PathComparer);
        dependencies.UnionWith(_watchedDirectories);
        dependencies.UnionWith(ResolvedDocumentFiles(ResolvedDocumentRoots()));

        var watched = _watchedDirectories.ToList();
        watched.Sort(PathComparer);
        var reload = dependencies.ToList();
        reload.Sort(PathComparer);
        return new BeancountSourceGraph(_sourceFiles.ToArray(), watched, reload, _sourceLines);
    }

    private void ResolveFile(string path)
    {
        var normalized = Path.GetFullPath(path);
        if (_activeStack.Contains(normalized))
        {
            throw new BeancountException("Beancount include cycle detected at " + normalized);
        }

        if (_visited.Contains(normalized))
        {
            return;
        }

        _activeStack.Add(normalized);
        try
        {
            string contents;
            try
            {
                contents = File.ReadAllText(normalized, StrictUtf8);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DecoderFallbackException or NotSupportedException)
            {
                throw new BeancountException($"Could not read {normalized}: {ex.Message}", ex);
            }

            _visited.Add(normalized);
            _sourceFiles.Add(normalized);
            var fileLines = BeancountSourceScanner.Lines(contents);
            _sourceLines[normalized] = fileLines;
            var directory = Path.GetDirectoryName(normalized) ?? normalized;

            foreach (var rawLine in fileLines)
            {
                var line = StripComment(rawLine).Trim();
                var quotedValues = QuotedStrings(line);
                var directive = FirstField(line);

                if (directive == "include" && quotedValues.Count > 0)
                {
                    List<string> includes;
                    try
                    {
                        includes = ResolveIncludePaths(quotedValues[0], directory);
                    }
                    catch (ArgumentException ex)
                    {
                        throw new BeancountException($"Invalid include path \"{quotedValues[0]}\" in {normalized}: {ex.Message}", ex);
                    }

                    foreach (var include in includes)
                    {
                        ResolveFile(include);
                    }
                }
                else if (directive == "option" && quotedValues.Count >= 2 && quotedValues[0] == "documents")
                {
                    _documentRootPaths.Add(quotedValues[1]);
                }
                else if (IsDocumentDirective(line) && quotedValues.Count > 0)
                {
                    _documentDeclarations.Add((quotedValues[0], directory));
                }
            }
        }
        finally
        {
            _activeStack.Remove(normalized);
        }
    }

    private List<string> ResolvedDocumentRoots()
    {
        var roots = new HashSet<string>(PathComparer);
        foreach (var path in _documentRootPaths)
        {
            roots.Add(ResolvePath(path, _mainDirectory));
        }

        var sorted = roots.ToList();
        sorted.Sort(PathComparer);
        return sorted;
    }

    // Beancount's document checks fail when a declared file goes missing, so each one is a reload dependency.
    private HashSet<string> ResolvedDocumentFiles(List<string> documentRoots)
    {
        var files = new HashSet<string>(PathComparer);
        foreach (var (path, sourceDirectory) in _documentDeclarations)
        {
            if (Path.IsPathFullyQualified(path))
            {
                files.UnionWith(DocumentFileDependencies(Path.GetFullPath(path)));
                continue;
            }

            files.UnionWith(DocumentFileDependencies(ResolvePath(path, sourceDirectory)));
            foreach (var root in documentRoots)
            {
                files.UnionWith(DocumentFileDependencies(ResolvePath(path, root)));
            }
        }

        return files;
    }

    /// <summary>The file, every link on the way to its target, and the final target: replacing any of them changes the document.</summary>
    private static HashSet<string> DocumentFileDependencies(string file)
    {
        var dependencies = new HashSet<string>(PathComparer) { file };
        var candidate = file;
        for (var depth = 0; depth < MaximumSymbolicLinkDepth; depth++)
        {
            string? destination;
            try
            {
                destination = new FileInfo(candidate).LinkTarget;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                break;
            }

            if (destination is null)
            {
                break;
            }

            var resolved = ResolvePath(destination, Path.GetDirectoryName(candidate) ?? candidate);
            if (!dependencies.Add(resolved))
            {
                break;
            }

            candidate = resolved;
        }

        try
        {
            if (new FileInfo(file).ResolveLinkTarget(returnFinalTarget: true) is { } target)
            {
                dependencies.Add(Path.GetFullPath(target.FullName));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // A broken or cyclic link is already watched through the links collected above.
        }

        return dependencies;
    }

    /// <summary>A line of the form <c>YYYY-MM-DD document ...</c>.</summary>
    private static bool IsDocumentDirective(string line)
    {
        var fields = line.Split((char[]?)null, 3, StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 2 || fields[1] != "document")
        {
            return false;
        }

        var dateParts = fields[0].Split('-', '/');
        return dateParts.Length == 3
            && dateParts[0].Length == 4
            && dateParts[1].Length is 1 or 2
            && dateParts[2].Length is 1 or 2
            && dateParts.All(part => part.Length > 0 && part.All(char.IsDigit));
    }

    private List<string> ResolveIncludePaths(string includePath, string directory)
    {
        if (!ContainsGlobPattern(includePath))
        {
            return [ResolvePath(includePath, directory)];
        }

        var patternPath = ResolvePath(includePath, directory);
        var searchRoot = GlobSearchRoot(patternPath);

        // A pattern that globs from the drive root would walk the whole disk.
        if (searchRoot is null)
        {
            return [];
        }

        if (!Directory.Exists(searchRoot))
        {
            if (ExistingWatchDirectory(searchRoot) is { } existing)
            {
                _watchedDirectories.Add(existing);
            }

            return [];
        }

        _watchedDirectories.Add(searchRoot);
        var regex = new Regex(GlobRegex(patternPath), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        var matches = new List<string>();
        var pending = new Stack<string>();
        pending.Push(searchRoot);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = new DirectoryInfo(current).EnumerateFileSystemInfos();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var entry in entries)
            {
                // Glob skips dot entries, as Beancount's glob does and the macOS app's enumeration does.
                if (entry.Name.StartsWith('.'))
                {
                    continue;
                }

                var fullName = Path.GetFullPath(entry.FullName);
                if (entry is DirectoryInfo directoryInfo)
                {
                    _watchedDirectories.Add(fullName);

                    // A junction back up the tree would loop forever, so links are watched but not descended.
                    if (!directoryInfo.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    {
                        pending.Push(fullName);
                    }

                    continue;
                }

                if (regex.IsMatch(fullName))
                {
                    matches.Add(fullName);
                }
            }
        }

        matches.Sort(PathComparer);
        return matches;
    }

    /// <summary>Beancount joins an include onto the including file's directory; an absolute include stands alone.</summary>
    internal static string ResolvePath(string path, string directory) => Path.GetFullPath(path, directory);

    private static bool ContainsGlobPattern(string path) => path.AsSpan().IndexOfAny("*?[") >= 0;

    /// <summary>The deepest directory above the first glob component, or null when that is a drive root.</summary>
    private static string? GlobSearchRoot(string patternPath)
    {
        var root = Path.GetPathRoot(patternPath) ?? string.Empty;
        var rest = patternPath[root.Length..];
        var components = rest.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries);
        var prefix = new List<string>();
        foreach (var component in components)
        {
            if (ContainsGlobPattern(component))
            {
                break;
            }

            prefix.Add(component);
        }

        return prefix.Count == 0 ? null : Path.Combine(root, Path.Combine([.. prefix]));
    }

    private static string? ExistingWatchDirectory(string missingDirectory)
    {
        var candidate = missingDirectory;
        while (Path.GetDirectoryName(candidate) is { } parent)
        {
            if (Directory.Exists(candidate))
            {
                return candidate;
            }

            candidate = parent;
        }

        return null;
    }

    /// <summary>
    /// Translates a glob over a full path: <c>*</c> and <c>?</c> stay inside one component, <c>**/</c> spans any
    /// number of them, and <c>[...]</c> is a character class. Either slash separates components.
    /// </summary>
    internal static string GlobRegex(string patternPath)
    {
        const string Separator = @"[\\/]";
        var regex = new StringBuilder("^");
        var index = 0;
        while (index < patternPath.Length)
        {
            var character = patternPath[index];
            if (character == '*')
            {
                if (index + 1 < patternPath.Length && patternPath[index + 1] == '*')
                {
                    if (index + 2 < patternPath.Length && patternPath[index + 2] is '/' or '\\')
                    {
                        regex.Append("(?:.*").Append(Separator).Append(")?");
                        index += 3;
                    }
                    else
                    {
                        regex.Append(".*");
                        index += 2;
                    }
                }
                else
                {
                    regex.Append(@"[^\\/]*");
                    index++;
                }
            }
            else if (character == '?')
            {
                regex.Append(@"[^\\/]");
                index++;
            }
            else if (character == '[')
            {
                var close = patternPath.IndexOf(']', index + 1);
                if (close >= 0)
                {
                    regex.Append(patternPath, index, close - index + 1);
                    index = close + 1;
                }
                else
                {
                    regex.Append(Regex.Escape("["));
                    index++;
                }
            }
            else if (character is '\\' or '/')
            {
                regex.Append(Separator);
                index++;
            }
            else
            {
                regex.Append(Regex.Escape(character.ToString()));
                index++;
            }
        }

        return regex.Append('$').ToString();
    }

    private static string? FirstField(string line)
    {
        var end = 0;
        while (end < line.Length && !char.IsWhiteSpace(line[end]))
        {
            end++;
        }

        return end == 0 ? null : line[..end];
    }

    internal static List<string> QuotedStrings(string line)
    {
        var values = new List<string>();
        var inQuote = false;
        var escaped = false;
        var current = new StringBuilder();
        foreach (var character in line)
        {
            if (escaped)
            {
                current.Append(character switch
                {
                    'b' => '\b',
                    'f' => '\f',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    _ => character,
                });
                escaped = false;
                continue;
            }

            if (character == '\\')
            {
                escaped = true;
                continue;
            }

            if (character == '"')
            {
                if (inQuote)
                {
                    values.Add(current.ToString());
                    current.Clear();
                }

                inQuote = !inQuote;
                continue;
            }

            if (inQuote)
            {
                current.Append(character);
            }
        }

        return values;
    }

    internal static string StripComment(string line)
    {
        var inQuote = false;
        var escaped = false;
        for (var i = 0; i < line.Length; i++)
        {
            var character = line[i];
            if (escaped)
            {
                escaped = false;
                continue;
            }

            if (character == '\\')
            {
                escaped = true;
                continue;
            }

            if (character == '"')
            {
                inQuote = !inQuote;
            }
            else if (character == ';' && !inQuote)
            {
                return line[..i];
            }
        }

        return line;
    }
}
