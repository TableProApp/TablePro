using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum ForeignApp
{
    TablePlus,
    SequelAce,
    DBeaver,
    DataGrip,
    BeekeeperStudio,
    Navicat,
    Dbx,
}

// Where other apps keep their files: the profile folder, %APPDATA% and %LOCALAPPDATA%.
public sealed record ForeignAppDirs(string Home, string Config, string Data)
{
    public static ForeignAppDirs ForCurrentUser() => new(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
}

public enum ForeignPasswordSource
{
    // The system's own store, which another app reads only on macOS; DataGrip can keep them in a KeePass file instead,
    // and DBX keeps there only the key to its own file.
    Keychain,
    // Its own files under a fixed key, decrypted while reading.
    AppFiles,
}

public enum ForeignSavedQuerySupport
{
    // Kept apart from the connections, while TablePro keeps each saved query with a connection.
    GlobalFolder,
    // Scripts import with the connection they run on; one with a default name starts unchecked.
    Scripts,
    // Query consoles import with their data source; one with a default name starts unchecked.
    Consoles,
    NotInExport,
}

// FileExtensions is set for an app imported from an export file the user picks, which is always available.
public sealed record ForeignSource(
    ForeignApp App,
    string Name,
    bool IsAvailable,
    long Connections,
    long SavedQueries,
    IReadOnlyList<string> FileExtensions,
    ForeignPasswordSource Passwords,
    ForeignSavedQuerySupport SavedQuerySupport)
{
    public bool PicksFile => FileExtensions.Count > 0;
}

public sealed record ForeignImportRequest(bool IncludePasswords, bool IncludeSavedQueries);

public enum ForeignPasswordOutcome
{
    NotRequested,
    Read,
    // A store was locked or would not open for this user, so the rest were not read.
    Stopped,
    // The app keeps them where Windows does not let another app read.
    LeftBehind,
}

public enum ForeignSslMode
{
    Disabled,
    Preferred,
    Required,
    VerifyCa,
    VerifyIdentity,
}

public enum TlsFileReason
{
    EngineLacks,
    ModeLacks,
    RelativePath,
    Incomplete,
}

// What the review says about a connection row. Paths are as the other app wrote them.
public abstract record ForeignRowNote
{
    private ForeignRowNote()
    {
    }

    public sealed record UnsupportedEngine(string Engine) : ForeignRowNote;

    public sealed record SshKeyMissing(string Path) : ForeignRowNote;

    public sealed record JumpHostKeyMissing(string Path) : ForeignRowNote;

    public sealed record CaCertificateMissing(string Path) : ForeignRowNote;

    public sealed record ClientCertificateMissing(string Path) : ForeignRowNote;

    public sealed record ClientKeyMissing(string Path) : ForeignRowNote;

    public sealed record TlsModeChanged(ForeignSslMode From, TlsMode To) : ForeignRowNote;

    public sealed record TlsSettingsNotRead : ForeignRowNote;

    public sealed record TlsFromDriverDefault(ForeignSslMode Mode) : ForeignRowNote;

    public sealed record TlsNotKept(ForeignSslMode From) : ForeignRowNote;

    public sealed record CaFileNotKept(string Path, TlsFileReason Reason) : ForeignRowNote;

    public sealed record ClientIdentityNotKept(TlsFileReason Reason) : ForeignRowNote;

    public sealed record SshNotKept : ForeignRowNote;

    public sealed record SshKeyNotKept(string Path) : ForeignRowNote;

    public sealed record JumpHostNotKept(string Host) : ForeignRowNote;

    public sealed record JumpHostPasswordNotKept(string Host) : ForeignRowNote;

    public sealed record JumpHostKeyNotKept(string Host, string Path) : ForeignRowNote;

    public sealed record FieldsNotKept(IReadOnlyList<string> Fields) : ForeignRowNote;
}

public sealed record ExistingConnection(Guid Id, string Name);

// Connection is the row as it would be saved, null when no engine here opens it; such a row cannot be checked.
public sealed record ForeignConnectionRow(
    string Reference,
    string Name,
    string Engine,
    SavedConnection? Connection,
    IReadOnlyList<string> GroupPath,
    ExistingConnection? Duplicate,
    IReadOnlyList<ForeignRowNote> Notes,
    int SavedQueryCount,
    bool CarriesPasswords);

// Connection is the reference of the connection row it runs on.
public sealed record ForeignQueryRow(
    string Reference,
    string Name,
    string? Connection,
    string? ConnectionName,
    long ByteCount);

// What a row does when a saved connection matches it.
public abstract record ForeignResolution
{
    private ForeignResolution()
    {
    }

    public sealed record Add : ForeignResolution
    {
        public static Add Instance { get; } = new();
    }

    public sealed record AddCopy : ForeignResolution
    {
        public static AddCopy Instance { get; } = new();
    }

    // Keeps the saved connection's id and passwords; offered only when both connect the same way.
    public sealed record Replace(Guid Id) : ForeignResolution;

    // Writes nothing, so the row's saved queries land on the saved connection.
    public sealed record KeepExisting(Guid Id) : ForeignResolution;
}

// Resolution is kept across an uncheck; Offered leaves out a Replace another checked row took.
public sealed record ForeignConnectionChoice(
    string Reference,
    bool Selected,
    ForeignResolution? Resolution,
    IReadOnlyList<ForeignResolution> Offered);

public enum ForeignQueryAvailability
{
    Available,
    // An earlier row takes the same name on the same connection.
    AddedByAnotherRow,
    TooLarge,
    NameTooLong,
    // Its connection is not imported, or its Replace went to another row.
    ConnectionSkipped,
    // The other app filed it under no connection.
    NoConnection,
}

public sealed record ForeignQueryChoice(string Reference, ForeignQueryAvailability Availability, bool Included);

// Importable is false when the checks write nothing.
public sealed record ForeignImportChoices(
    IReadOnlyList<ForeignConnectionChoice> Connections,
    IReadOnlyList<ForeignQueryChoice> Queries,
    bool Importable);

// PasswordsNotKept: refused by Credential Manager, so those connections ask when they connect.
public sealed record ForeignImportOutcome(
    int Connections,
    int Replaced,
    int PasswordsNotKept,
    int QueriesAdded,
    int QueriesAlreadySaved,
    int QueriesFailed);

// Another app's connections and saved queries, read once and checked against the library as it was then.
public sealed class ForeignImportReview : IDisposable
{
    private readonly Native.ForeignImportReview _review;

    internal ForeignImportReview(Native.ForeignImportReview review)
    {
        _review = review;
        App = Mapping.ForeignApp(review.App());
        Passwords = Mapping.Outcome(review.Passwords());
        Connections = [.. review.Connections().Select(Mapping.ForeignRow)];
        SavedQueries = [.. review.SavedQueries().Select(query => new ForeignQueryRow(
            query.Reference,
            query.Name,
            query.Connection,
            query.ConnectionName,
            Mapping.Count(query.ByteCount)))];
    }

    public ForeignApp App { get; }

    public ForeignPasswordOutcome Passwords { get; }

    public IReadOnlyList<ForeignConnectionRow> Connections { get; }

    public IReadOnlyList<ForeignQueryRow> SavedQueries { get; }

    // Worked out again from the checks, so read it after each change.
    public ForeignImportChoices Choices()
    {
        var choices = CoreCall.Run(_review.Choices);
        return new ForeignImportChoices(
            [.. choices.Connections.Select(choice => new ForeignConnectionChoice(
                choice.Reference,
                choice.Selected,
                choice.Resolution is { } resolution ? Mapping.Resolution(resolution) : null,
                [.. choice.Offered.Select(Mapping.Resolution)]))],
            [.. choices.Queries.Select(query => new ForeignQueryChoice(
                query.Reference,
                Mapping.Availability(query.Availability),
                query.Included))],
            choices.Importable);
    }

    public void SetSelected(string reference, bool selected)
    {
        ArgumentNullException.ThrowIfNull(reference);
        CoreCall.Run(() =>
        {
            _review.SetSelected(reference, selected);
            return true;
        });
    }

    // False when the row does not offer it, or another checked row took that Replace.
    public bool Resolve(string reference, ForeignResolution resolution)
    {
        ArgumentNullException.ThrowIfNull(reference);
        ArgumentNullException.ThrowIfNull(resolution);
        return CoreCall.Run(() => _review.Resolve(reference, Mapping.Resolution(resolution)));
    }

    public void SetIncluded(string reference, bool included)
    {
        ArgumentNullException.ThrowIfNull(reference);
        CoreCall.Run(() =>
        {
            _review.SetIncluded(reference, included);
            return true;
        });
    }

    // Once; storage.import_outdated when the library changed since the read, with nothing written. A new connection
    // lands in projectId; one that replaces a saved connection keeps its project.
    public async Task<ForeignImportOutcome> ApplyAsync(Guid? projectId = null)
    {
        var outcome = await CoreCall.RunAsync(() => _review.Apply(projectId?.ToString())).ConfigureAwait(false);
        return new ForeignImportOutcome(
            checked((int)outcome.Connections),
            checked((int)outcome.Replaced),
            checked((int)outcome.PasswordsNotKept),
            checked((int)outcome.QueriesAdded),
            checked((int)outcome.QueriesAlreadySaved),
            checked((int)outcome.QueriesFailed));
    }

    public void Dispose() => _review.Dispose();
}
