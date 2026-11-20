using TablePro.Interop;

namespace TablePro.App.Model;

// The core calls an import from another app makes.
public interface IForeignImporter
{
    Task<IReadOnlyList<ForeignSource>> GetSourcesAsync();

    // File is the export the user picked, for an app imported from one. Throws foreign_import.* codes.
    Task<IForeignReview> ReadAsync(
        ForeignApp app,
        string? file,
        ForeignImportRequest request,
        CancellationToken cancellationToken);
}

// One read of another app, as ForeignImportReview holds it.
public interface IForeignReview : IDisposable
{
    ForeignApp App { get; }

    ForeignPasswordOutcome Passwords { get; }

    IReadOnlyList<ForeignConnectionRow> Connections { get; }

    IReadOnlyList<ForeignQueryRow> SavedQueries { get; }

    ForeignImportChoices Choices();

    void SetSelected(string reference, bool selected);

    bool Resolve(string reference, ForeignResolution resolution);

    void SetIncluded(string reference, bool included);

    // A new connection lands in the project; one that replaces a saved connection keeps its own.
    Task<ForeignImportOutcome> ApplyAsync(Guid? projectId);
}

public sealed class CoreForeignImporter(TableProCore core, ForeignAppDirs dirs) : IForeignImporter
{
    public Task<IReadOnlyList<ForeignSource>> GetSourcesAsync() => core.GetForeignSourcesAsync(dirs);

    public async Task<IForeignReview> ReadAsync(
        ForeignApp app,
        string? file,
        ForeignImportRequest request,
        CancellationToken cancellationToken) =>
        new CoreForeignReview(
            await core.ReadForeignAsync(app, dirs, file, request, cancellationToken).ConfigureAwait(true));

    private sealed class CoreForeignReview(ForeignImportReview review) : IForeignReview
    {
        public ForeignApp App => review.App;

        public ForeignPasswordOutcome Passwords => review.Passwords;

        public IReadOnlyList<ForeignConnectionRow> Connections => review.Connections;

        public IReadOnlyList<ForeignQueryRow> SavedQueries => review.SavedQueries;

        public ForeignImportChoices Choices() => review.Choices();

        public void SetSelected(string reference, bool selected) => review.SetSelected(reference, selected);

        public bool Resolve(string reference, ForeignResolution resolution) => review.Resolve(reference, resolution);

        public void SetIncluded(string reference, bool included) => review.SetIncluded(reference, included);

        public Task<ForeignImportOutcome> ApplyAsync(Guid? projectId) => review.ApplyAsync(projectId);

        public void Dispose() => review.Dispose();
    }
}

public enum ForeignImportStep
{
    Loading,
    Choosing,
    Reading,
    Reviewing,
    Importing,
    Done,
}

public enum ForeignSourceNote
{
    // The counts say what it holds.
    Found,
    NotFound,
    PicksFile,
}

public enum ForeignPasswordNote
{
    DecryptedWhileReading,

    // DataGrip can keep them in a KeePass file, which the core opens with DPAPI.
    PasswordFile,

    // DBX encrypts them under a key it keeps in Credential Manager, which the core reads.
    KeyInCredentialManager,

    // Where Windows does not let another app read them.
    SystemStore,
}

public sealed record ForeignPasswordOption(bool Offered, bool Checked, ForeignPasswordNote Note);

public sealed record ForeignQueryOption(bool Offered, bool Checked, ForeignSavedQuerySupport Support);

public enum ForeignReadFailureKind
{
    NotFound,
    NothingFound,

    // Files of a version or shape the core does not know.
    Unreadable,

    // The saved connections to compare against could not be read.
    Library,
    Other,
}

public sealed record ForeignReadFailure(ForeignApp App, ForeignReadFailureKind Kind, CoreError Error)
{
    public static ForeignReadFailure From(ForeignApp app, CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var kind = error.Code switch
        {
            "foreign_import.file_not_found" => ForeignReadFailureKind.NotFound,
            "foreign_import.nothing_found" => ForeignReadFailureKind.NothingFound,
            "foreign_import.unreadable" or "foreign_import.parse" or "foreign_import.unsupported_format" =>
                ForeignReadFailureKind.Unreadable,
            "ffi.no_storage" => ForeignReadFailureKind.Library,
            var code when code.StartsWith("storage.", StringComparison.Ordinal) => ForeignReadFailureKind.Library,
            _ => ForeignReadFailureKind.Other,
        };
        return new ForeignReadFailure(app, kind, error);
    }
}

// Offered is what the resolution box lists: a Replace another checked row took is left out.
public sealed record ForeignConnectionLine(
    ForeignConnectionRow Row,
    bool Selected,
    ForeignResolution? Resolution,
    IReadOnlyList<ForeignResolution> Offered)
{
    public string Reference => Row.Reference;

    // No engine here opens it.
    public bool Selectable => Row.Connection is not null;

    public bool ShowsResolution => Row.Duplicate is not null && Selected;

    public bool CanResolve => ShowsResolution && Offered.Count > 1;
}

// Availability is null while the core has no choice for the row.
public sealed record ForeignQueryLine(ForeignQueryRow Row, ForeignQueryAvailability? Availability, bool Included)
{
    public string Reference => Row.Reference;

    public bool Importable => Availability == ForeignQueryAvailability.Available;
}

public sealed record ForeignImportSummary(int SelectedConnections, int Connections, int IncludedQueries, int Queries);

public enum ForeignImportPart
{
    Connections,
    QueriesAdded,
    QueriesNotAdded,
    PasswordsNotKept,
    Nothing,
    Outdated,
    Failed,
}

public sealed record ForeignImportSentence(ForeignImportPart Part, int Count = 0);

// Outcome is set once the import wrote, Error when it refused; Sentences are in the order the bar shows them.
public sealed record ForeignImportEnding(
    IReadOnlyList<ForeignImportSentence> Sentences,
    ForeignImportOutcome? Outcome,
    CoreError? Error)
{
    public const string OutdatedCode = "storage.import_outdated";

    public bool Wrote => Outcome is not null;

    public bool Outdated => Error?.Code == OutdatedCode;

    // Some passwords or saved queries did not land.
    public bool Partial => Outcome is { PasswordsNotKept: > 0 } or { QueriesFailed: > 0 };

    public bool Nothing => Outcome is { Connections: 0, QueriesAdded: 0 };

    public static ForeignImportEnding From(ForeignImportOutcome outcome)
    {
        ArgumentNullException.ThrowIfNull(outcome);
        List<ForeignImportSentence> sentences = [];
        if (outcome.Connections > 0)
        {
            sentences.Add(new ForeignImportSentence(ForeignImportPart.Connections, outcome.Connections));
        }

        if (outcome.QueriesAdded > 0)
        {
            sentences.Add(new ForeignImportSentence(ForeignImportPart.QueriesAdded, outcome.QueriesAdded));
        }

        if (outcome.QueriesFailed > 0)
        {
            sentences.Add(new ForeignImportSentence(ForeignImportPart.QueriesNotAdded, outcome.QueriesFailed));
        }

        if (outcome.PasswordsNotKept > 0)
        {
            sentences.Add(new ForeignImportSentence(ForeignImportPart.PasswordsNotKept, outcome.PasswordsNotKept));
        }

        if (sentences.Count == 0)
        {
            sentences.Add(new ForeignImportSentence(ForeignImportPart.Nothing));
        }

        return new ForeignImportEnding(sentences, outcome, null);
    }

    public static ForeignImportEnding Refused(CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var part = error.Code == OutdatedCode ? ForeignImportPart.Outdated : ForeignImportPart.Failed;
        return new ForeignImportEnding([new ForeignImportSentence(part)], null, error);
    }
}

// The macOS Import from Other App sheet's steps: the app and what to bring, the read, then the review of each row.
public sealed class ForeignImportForm : IDisposable
{
    private readonly IForeignImporter _importer;
    private IForeignReview? _review;
    private bool _importable;

    // The boxes' own answers, kept while an app that cannot honour one is chosen.
    private bool _wantsPasswords = true;
    private bool _wantsQueries = true;

    // A read the user left for another is dropped when it lands.
    private int _read;

    public ForeignImportForm(IForeignImporter importer, Guid? projectId = null)
    {
        ArgumentNullException.ThrowIfNull(importer);
        _importer = importer;
        ProjectId = projectId;
    }

    // The project the app showed when the dialog opened, where the new connections land.
    public Guid? ProjectId { get; }

    public ForeignImportStep Step { get; private set; }

    public IReadOnlyList<ForeignSource> Sources { get; private set; } = [];

    // Set when the apps could not be looked for, which leaves the list empty.
    public CoreError? SourcesError { get; private set; }

    public ForeignSource? Chosen { get; private set; }

    // The last read's, shown on the first page until another app or read.
    public ForeignReadFailure? Failure { get; private set; }

    public ForeignPasswordOption Passwords => PasswordOption(Chosen, _wantsPasswords);

    public ForeignQueryOption Queries => QueryOption(Chosen, _wantsQueries);

    public bool CanContinue => Step == ForeignImportStep.Choosing && Chosen is { IsAvailable: true };

    public ForeignApp? ReviewedApp => _review?.App;

    public ForeignPasswordOutcome PasswordOutcome => _review?.Passwords ?? ForeignPasswordOutcome.NotRequested;

    // A new list after each change, since a check can move another row.
    public IReadOnlyList<ForeignConnectionLine> Connections { get; private set; } = [];

    public IReadOnlyList<ForeignQueryLine> SavedQueries { get; private set; } = [];

    public ForeignImportSummary Summary { get; private set; } = new(0, 0, 0, 0);

    public bool CanImport => Step == ForeignImportStep.Reviewing && _importable;

    public static ForeignSourceNote NoteFor(ForeignSource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return source.PicksFile ? ForeignSourceNote.PicksFile
            : source.IsAvailable ? ForeignSourceNote.Found
            : ForeignSourceNote.NotFound;
    }

    // The first app found is chosen.
    public async Task LoadAsync()
    {
        if (Step != ForeignImportStep.Loading)
        {
            return;
        }

        try
        {
            Sources = await _importer.GetSourcesAsync().ConfigureAwait(true);
            SourcesError = null;
        }
        catch (TableProException exception)
        {
            Sources = [];
            SourcesError = exception.Error;
        }

        if (Step != ForeignImportStep.Loading)
        {
            return;
        }

        Chosen = Sources.FirstOrDefault(source => source.IsAvailable);
        Step = ForeignImportStep.Choosing;
    }

    // False for an app not found here.
    public bool Choose(ForeignApp app)
    {
        if (Step != ForeignImportStep.Choosing
            || Sources.FirstOrDefault(source => source.App == app) is not { IsAvailable: true } source)
        {
            return false;
        }

        Chosen = source;
        Failure = null;
        return true;
    }

    public void SetPasswords(bool wanted)
    {
        if (Passwords.Offered)
        {
            _wantsPasswords = wanted;
        }
    }

    public void SetQueries(bool wanted)
    {
        if (Queries.Offered)
        {
            _wantsQueries = wanted;
        }
    }

    public ForeignImportRequest Request()
    {
        var passwords = Passwords;
        // An app that keeps them where Windows does not let us read is still asked, so the review says they stayed.
        var includePasswords = passwords.Offered
            ? passwords.Checked
            : Chosen?.Passwords == ForeignPasswordSource.Keychain;
        return new ForeignImportRequest(includePasswords, Queries is { Offered: true, Checked: true });
    }

    // File is the export the user picked. False when the read failed, was cancelled or was left for another.
    public async Task<bool> ReadAsync(string? file, CancellationToken cancellationToken = default)
    {
        if (!CanContinue || Chosen is not { } source || (source.PicksFile && string.IsNullOrEmpty(file)))
        {
            return false;
        }

        var read = ++_read;
        var request = Request();
        Step = ForeignImportStep.Reading;
        Failure = null;
        try
        {
            var review = await _importer
                .ReadAsync(source.App, source.PicksFile ? file : null, request, cancellationToken)
                .ConfigureAwait(true);
            if (read != _read || Step != ForeignImportStep.Reading)
            {
                review.Dispose();
                return false;
            }

            _review = review;
            Step = ForeignImportStep.Reviewing;
            Refresh();
            return true;
        }
        catch (TableProException exception)
        {
            if (read == _read && Step == ForeignImportStep.Reading)
            {
                Failure = ForeignReadFailure.From(source.App, exception.Error);
                Step = ForeignImportStep.Choosing;
            }

            return false;
        }
        catch (OperationCanceledException)
        {
            if (read == _read && Step == ForeignImportStep.Reading)
            {
                Step = ForeignImportStep.Choosing;
            }

            return false;
        }
    }

    public void SetSelected(string reference, bool selected)
    {
        ArgumentNullException.ThrowIfNull(reference);
        if (Reviewing() is { } review)
        {
            review.SetSelected(reference, selected);
            Refresh();
        }
    }

    // False when the row does not offer it, or another checked row took that Replace.
    public bool Resolve(string reference, ForeignResolution resolution)
    {
        ArgumentNullException.ThrowIfNull(reference);
        ArgumentNullException.ThrowIfNull(resolution);
        if (Reviewing() is not { } review)
        {
            return false;
        }

        var resolved = review.Resolve(reference, resolution);
        Refresh();
        return resolved;
    }

    public void SetIncluded(string reference, bool included)
    {
        ArgumentNullException.ThrowIfNull(reference);
        if (Reviewing() is { } review)
        {
            review.SetIncluded(reference, included);
            Refresh();
        }
    }

    // Null when there is nothing to import yet. The import runs once, refused or not.
    public async Task<ForeignImportEnding?> ImportAsync()
    {
        if (!CanImport || _review is not { } review)
        {
            return null;
        }

        Step = ForeignImportStep.Importing;
        try
        {
            return ForeignImportEnding.From(await review.ApplyAsync(ProjectId).ConfigureAwait(true));
        }
        catch (TableProException exception)
        {
            return ForeignImportEnding.Refused(exception.Error);
        }
        finally
        {
            Step = ForeignImportStep.Done;
        }
    }

    public void Dispose()
    {
        Step = ForeignImportStep.Done;
        _review?.Dispose();
        _review = null;
    }

    private IForeignReview? Reviewing() => Step == ForeignImportStep.Reviewing ? _review : null;

    private void Refresh()
    {
        if (_review is not { } review)
        {
            return;
        }

        var choices = review.Choices();
        var connections = new Dictionary<string, ForeignConnectionChoice>(StringComparer.Ordinal);
        foreach (var choice in choices.Connections)
        {
            connections.TryAdd(choice.Reference, choice);
        }

        var queries = new Dictionary<string, ForeignQueryChoice>(StringComparer.Ordinal);
        foreach (var choice in choices.Queries)
        {
            queries.TryAdd(choice.Reference, choice);
        }

        Connections = [.. review.Connections.Select(row => connections.TryGetValue(row.Reference, out var choice)
            ? new ForeignConnectionLine(row, choice.Selected, choice.Resolution, choice.Offered)
            : new ForeignConnectionLine(row, false, null, []))];
        SavedQueries = [.. review.SavedQueries.Select(row => queries.TryGetValue(row.Reference, out var choice)
            ? new ForeignQueryLine(row, choice.Availability, choice.Included)
            : new ForeignQueryLine(row, null, false))];
        Summary = new ForeignImportSummary(
            Connections.Count(line => line.Selected),
            Connections.Count,
            SavedQueries.Count(line => line.Included),
            SavedQueries.Count);
        _importable = choices.Importable;
    }

    private static ForeignPasswordOption PasswordOption(ForeignSource? source, bool wanted)
    {
        var note = source switch
        {
            null or { Passwords: ForeignPasswordSource.AppFiles } => ForeignPasswordNote.DecryptedWhileReading,
            { App: ForeignApp.DataGrip } => ForeignPasswordNote.PasswordFile,
            { App: ForeignApp.Dbx } => ForeignPasswordNote.KeyInCredentialManager,
            _ => ForeignPasswordNote.SystemStore,
        };
        var offered = source is not null && note != ForeignPasswordNote.SystemStore;
        return new ForeignPasswordOption(offered, offered && wanted, note);
    }

    private static ForeignQueryOption QueryOption(ForeignSource? source, bool wanted)
    {
        var support = source?.SavedQuerySupport ?? ForeignSavedQuerySupport.NotInExport;
        var offered = support is ForeignSavedQuerySupport.Scripts or ForeignSavedQuerySupport.Consoles;
        return new ForeignQueryOption(offered, offered && wanted, support);
    }
}
