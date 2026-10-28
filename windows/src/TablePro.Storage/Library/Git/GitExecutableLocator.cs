namespace TablePro.Storage.Library.Git;

/// <summary>
/// Finds <c>git.exe</c>: on the PATH first, as a terminal would, then where the Git for Windows installer puts it
/// for all users and for one user. The macOS app searches Homebrew and Xcode the same way.
/// </summary>
public sealed class GitExecutableLocator(Func<string, bool> fileExists, Func<string, string?> environment)
{
    public static GitExecutableLocator System { get; } = new(File.Exists, global::System.Environment.GetEnvironmentVariable);

    public IReadOnlyList<string> Candidates()
    {
        var candidates = new List<string>();
        foreach (var entry in (environment("PATH") ?? string.Empty).Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var directory = entry.Trim('"');

            // A relative PATH entry resolves against the current folder, which may be a cloned repository that
            // carries its own git.exe.
            if (!Path.IsPathFullyQualified(directory))
            {
                continue;
            }

            candidates.Add(Path.Combine(directory, "git.exe"));
        }

        foreach (var (variable, relative) in new[]
        {
            ("ProgramFiles", @"Git\cmd\git.exe"),
            ("ProgramW6432", @"Git\cmd\git.exe"),
            ("ProgramFiles(x86)", @"Git\cmd\git.exe"),
            ("LOCALAPPDATA", @"Programs\Git\cmd\git.exe"),
        })
        {
            if (environment(variable) is { Length: > 0 } root && Path.IsPathFullyQualified(root))
            {
                candidates.Add(Path.Combine(root, relative));
            }
        }

        return [.. candidates.Distinct(StringComparer.OrdinalIgnoreCase)];
    }

    public string? Locate() => Candidates().FirstOrDefault(fileExists);
}
