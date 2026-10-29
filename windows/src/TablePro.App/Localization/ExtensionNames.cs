using TablePro.Core.Connections;

namespace TablePro.App.Localization;

/// <summary>
/// The wording for Core's SQLite extension failures as the app shows them: the cause on its own line, followed by
/// what to do about it, which Core's one-line message does not say.
/// </summary>
internal static class ExtensionNames
{
    /// <summary>What went wrong, what the cause was and, when there is one, what to do: the connect error's body.</summary>
    public static string Describe(LoadableExtensionException error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var head = error.Extension is { } item
            ? Strings.Format("Extensions/CouldNotLoad", item.FileName)
            : Strings.Get("Extensions/CouldNotLoadList");
        return string.Join("\n\n", new[] { head, Reason(error), Recovery(error) }.Where(s => !string.IsNullOrEmpty(s)));
    }

    /// <summary>The cause alone, as the connection form shows a list it will not save.</summary>
    public static string Reason(LoadableExtensionException error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var item = error.Extension;
        return error.Failure switch
        {
            LoadableExtensionFailure.MalformedList => Strings.Get("Extensions/MalformedList"),
            LoadableExtensionFailure.MissingPath => Strings.Get("Extensions/MissingPath"),
            LoadableExtensionFailure.ControlCharacterInPath => Strings.Get("Extensions/ControlCharacterInPath"),
            LoadableExtensionFailure.RelativePath => Strings.Format("Extensions/RelativePath", item?.Path),
            LoadableExtensionFailure.PathTooLong => Strings.Format("Extensions/PathTooLong", item?.Path),
            LoadableExtensionFailure.InvalidEntryPoint => Strings.Format("Extensions/InvalidEntryPoint", item?.EntryPoint),
            LoadableExtensionFailure.Duplicate => Strings.Format("Extensions/Duplicate", item?.Path),
            LoadableExtensionFailure.FileNotFound => Strings.Format("Extensions/FileNotFound", item?.Path),
            LoadableExtensionFailure.NotAFile => Strings.Format("Extensions/NotAFile", item?.Path),
            LoadableExtensionFailure.EntryPointNotFound => Strings.Format("Extensions/EntryPointNotFound", error.Detail),
            LoadableExtensionFailure.InitializationFailed => Strings.Format("Extensions/InitializationFailed", error.Detail),
            LoadableExtensionFailure.LoadingUnavailable => Strings.Get("Extensions/LoadingUnavailable"),
            LoadableExtensionFailure.LoadingNotClosed => Strings.Get("Extensions/LoadingNotClosed"),
            _ => error.Detail ?? error.Message,
        };
    }

    private static string? Recovery(LoadableExtensionException error) => error.Failure switch
    {
        LoadableExtensionFailure.RelativePath => Strings.Get("Extensions/RelativePathRecovery"),
        LoadableExtensionFailure.InvalidEntryPoint => Strings.Get("Extensions/InvalidEntryPointRecovery"),
        LoadableExtensionFailure.Duplicate => Strings.Get("Extensions/DuplicateRecovery"),
        LoadableExtensionFailure.FileNotFound or LoadableExtensionFailure.NotAFile or LoadableExtensionFailure.ControlCharacterInPath => Strings.Get("Extensions/ChooseAgainRecovery"),
        LoadableExtensionFailure.EntryPointNotFound => Strings.Get("Extensions/EntryPointNotFoundRecovery"),
        LoadableExtensionFailure.LibraryNotLoaded when error.IsWrongArchitecture => Strings.Get("Extensions/WrongArchitectureRecovery"),
        LoadableExtensionFailure.LibraryNotLoaded when error.IsMissingDependency => Strings.Get("Extensions/MissingDependencyRecovery"),
        _ => null,
    };

    /// <summary>One line per file, naming the entry point when the list gives one.</summary>
    public static string Files(IEnumerable<LoadableExtension> extensions) =>
        string.Join('\n', extensions.Select(e => e.EntryPoint is { } entryPoint ? Strings.Format("Extensions/FileWithEntryPoint", e.Path, entryPoint) : e.Path));

    /// <summary>
    /// A connection name arrives with the connection, from an import or the team library, so it may not add lines of
    /// its own to a message whose other lines name the code about to run.
    /// </summary>
    public static string SingleLine(string text) =>
        string.Create(text.Length, text, static (span, source) =>
        {
            for (var i = 0; i < source.Length; i++)
            {
                var c = source[i];
                span[i] = char.IsControl(c) || c is '\x2028' or '\x2029' or '\x85' ? ' ' : c;
            }
        });
}
