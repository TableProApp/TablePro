using TablePro.Ssh.Localization;

namespace TablePro.Ssh;

/// <summary>
/// Finds the helper programs tunnels run. Only <c>.exe</c> and <c>.com</c> files are accepted: Windows starts a
/// <c>.cmd</c> or <c>.bat</c> through cmd.exe, which parses the argument list again as a shell string, and tunnel
/// arguments carry host names the app does not control.
/// </summary>
public static class ExecutableLocator
{
    private static readonly string[] RunnableExtensions = [".exe", ".com"];
    private static readonly string[] ScriptExtensions = [".cmd", ".bat"];

    /// <summary>
    /// Resolves <paramref name="nameOrPath"/>: a path is checked as given, a bare name is looked up on PATH and then
    /// in <paramref name="extraDirectories"/>, the install folders a GUI app started from the Start menu may not have
    /// on its PATH.
    /// </summary>
    /// <returns>The full path, or null when nothing runnable has that name.</returns>
    /// <exception cref="TunnelException">The name resolves only to a batch script.</exception>
    public static string? Find(string nameOrPath, IEnumerable<string>? extraDirectories = null, string? pathVariable = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(nameOrPath);
        var name = Environment.ExpandEnvironmentVariables(nameOrPath.Trim().Trim('"'));
        if (name.Contains(Path.DirectorySeparatorChar) || name.Contains(Path.AltDirectorySeparatorChar))
        {
            return Runnable(name) ?? Runnable(name + ".exe") ?? RefuseScript(name);
        }

        var directories = (pathVariable ?? Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(d => d.Trim('"'))
            .Concat(extraDirectories ?? []);

        string? script = null;
        foreach (var directory in directories)
        {
            string candidate;
            try
            {
                candidate = Path.Combine(directory, name);
            }
            catch (ArgumentException)
            {
                continue;
            }

            if (Runnable(candidate) is { } found)
            {
                return found;
            }

            foreach (var extension in RunnableExtensions)
            {
                if (File.Exists(candidate + extension))
                {
                    return candidate + extension;
                }
            }

            script ??= ScriptExtensions.Select(e => candidate + e).FirstOrDefault(File.Exists);
        }

        return script is null ? null : RefuseScript(script);
    }

    /// <summary>Install folders for the Google Cloud SDK, where <c>gcloud components install cloud-sql-proxy</c> puts it.</summary>
    public static IEnumerable<string> GoogleCloudSdkDirectories() =>
        KnownFolders(
            (Environment.SpecialFolder.LocalApplicationData, @"Google\Cloud SDK\google-cloud-sdk\bin"),
            (Environment.SpecialFolder.ProgramFilesX86, @"Google\Cloud SDK\google-cloud-sdk\bin"),
            (Environment.SpecialFolder.ProgramFiles, @"Google\Cloud SDK\google-cloud-sdk\bin"));

    /// <summary>Where the cloudflared MSI and winget install it.</summary>
    public static IEnumerable<string> CloudflaredDirectories() =>
        KnownFolders(
            (Environment.SpecialFolder.ProgramFilesX86, "cloudflared"),
            (Environment.SpecialFolder.ProgramFiles, "cloudflared"),
            (Environment.SpecialFolder.LocalApplicationData, @"Microsoft\WinGet\Links"));

    /// <summary>winget's shim folder, which a GUI app started before the install has not got on its PATH.</summary>
    public static IEnumerable<string> PackageManagerDirectories() =>
        KnownFolders((Environment.SpecialFolder.LocalApplicationData, @"Microsoft\WinGet\Links"));

    private static IEnumerable<string> KnownFolders(params (Environment.SpecialFolder Root, string Relative)[] folders)
    {
        foreach (var (root, relative) in folders)
        {
            var path = Environment.GetFolderPath(root);
            if (!string.IsNullOrEmpty(path))
            {
                yield return Path.Combine(path, relative);
            }
        }
    }

    private static string? Runnable(string path) =>
        File.Exists(path) && RunnableExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase) ? Path.GetFullPath(path) : null;

    private static string? RefuseScript(string path)
    {
        var extension = Path.GetExtension(path);
        if (File.Exists(path) && ScriptExtensions.Contains(extension, StringComparer.OrdinalIgnoreCase))
        {
            throw new TunnelException(
                TunnelFailureKind.ExecutableNotFound,
                SshStrings.Format("Tunnel/BatchScript", path));
        }

        return null;
    }
}
