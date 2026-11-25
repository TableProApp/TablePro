using TablePro.Interop;

namespace TablePro.App.Model;

public enum SetupStep
{
    Origin,
    Import,
    FirstConnection,
    Options,
}

// Where the user comes from, picked on the first step; a connections file goes through File > Import instead.
public enum SetupOrigin
{
    New,
    OtherApp,
}

public enum FirstConnectionChoice
{
    NewConnection,
    Sample,
}

// Connections counts the sample; groups do not count (core 0051, The gate).
// LaunchWork: a file the launch opened waits on the Connections page, and the guide must not cover it (ADR 0051, G8).
public sealed record SetupGate(bool FromMenu, bool LibraryRead, int Connections, bool Seen, bool LaunchWork = false);

public enum ImportSource
{
    // Another app's own store on this computer: the user's own data.
    ThisComputer,

    // A connections file, a link or an export the user picked, which anyone could have sent.
    FileOrLink,
}

// What Finish and Skip leave the user with.
public abstract record SetupEnding
{
    private SetupEnding()
    {
    }

    public sealed record Open(Guid Id) : SetupEnding;

    public sealed record SelectInLibrary(IReadOnlyList<Guid> Ids) : SetupEnding
    {
        public bool Equals(SelectInLibrary? other) => other is not null && Ids.SequenceEqual(other.Ids);

        public override int GetHashCode() => Ids.Count;
    }

    public sealed record NewConnection : SetupEnding
    {
        public static NewConnection Instance { get; } = new();
    }

    public sealed record Sample : SetupEnding
    {
        public static Sample Instance { get; } = new();
    }

    public sealed record Stay : SetupEnding
    {
        public static Stay Instance { get; } = new();
    }
}

// The setup guide's steps, its recorded first connection and the ids its imports wrote (core 0051, Steps).
public sealed class SetupGuide
{
    // How long the launch's look for other apps may take before the guide stays on its first step.
    public static readonly TimeSpan ProbeLimit = TimeSpan.FromSeconds(2);

    private readonly IForeignImporter _importer;
    private readonly Stack<SetupStep> _history = new();
    private readonly HashSet<ForeignApp> _ticked = [];
    private readonly List<Guid> _imported = [];
    private ImportSource _importSource = ImportSource.ThisComputer;
    private bool _moved;

    public SetupGuide(IForeignImporter importer, SetupStep first)
    {
        ArgumentNullException.ThrowIfNull(importer);
        _importer = importer;
        Step = first;
    }

    public event EventHandler? Changed;

    public SetupStep Step { get; private set; }

    public bool CanGoBack => _history.Count > 0;

    public IReadOnlyList<ForeignSource> Sources { get; private set; } = [];

    // Set when the apps could not be looked for, which leaves the list empty.
    public CoreError? SourcesError { get; private set; }

    public bool SourcesLoaded { get; private set; }

    // The ticked sources in list order, the order the import step reads them in.
    public IReadOnlyList<ForeignSource> Queue => [.. Sources.Where(source => _ticked.Contains(source.App))];

    public FirstConnectionChoice? Recorded { get; private set; }

    public IReadOnlyList<Guid> Imported => _imported;

    public static bool ShouldShow(SetupGate gate)
    {
        ArgumentNullException.ThrowIfNull(gate);
        return gate.FromMenu || (gate.LibraryRead && gate.Connections == 0 && !gate.Seen && !gate.LaunchWork);
    }

    // A file or link can come from anyone, and a connect may sign in with the user's Windows account.
    public static SetupEnding Handoff(IReadOnlyList<Guid> ids, ImportSource source)
    {
        ArgumentNullException.ThrowIfNull(ids);
        return ids.Count switch
        {
            0 => SetupEnding.Stay.Instance,
            1 when source == ImportSource.ThisComputer => new SetupEnding.Open(ids[0]),
            _ => new SetupEnding.SelectInLibrary([.. ids]),
        };
    }

    // True when an app other than a picked file is there; a failure or an answer past the limit reads as none.
    public static async Task<bool> ProbeAsync(IForeignImporter importer, TimeSpan limit)
    {
        ArgumentNullException.ThrowIfNull(importer);
        var probe = Task.Run(() => importer.GetSourcesAsync(ForeignScanDepth.Presence));
        if (await Task.WhenAny(probe, Task.Delay(limit)).ConfigureAwait(true) != probe)
        {
            _ = probe.ContinueWith(task => task.Exception, TaskScheduler.Default);
            return false;
        }

        try
        {
            return (await probe.ConfigureAwait(true)).Any(source => source.IsAvailable && !source.PicksFile);
        }
        catch (TableProException)
        {
            return false;
        }
    }

    // The probe's answer moves a guide still on its first step, untouched, to the import step.
    public void Probed(bool found)
    {
        if (found && !_moved && Step == SetupStep.Origin && _history.Count == 0)
        {
            Step = SetupStep.Import;
            Raise();
        }
    }

    // Inventory reads the counts; a source starts ticked when the core says so.
    public async Task LoadSourcesAsync()
    {
        try
        {
            Sources = await _importer.GetSourcesAsync(ForeignScanDepth.Inventory).ConfigureAwait(true);
            SourcesError = null;
        }
        catch (TableProException exception)
        {
            Sources = [];
            SourcesError = exception.Error;
        }

        _ticked.Clear();
        foreach (var source in Sources.Where(source => source.StartsTicked))
        {
            _ticked.Add(source.App);
        }

        SourcesLoaded = true;
        Raise();
    }

    public bool IsTicked(ForeignApp app) => _ticked.Contains(app);

    // False for a source that cannot be read here.
    public bool SetTicked(ForeignApp app, bool ticked)
    {
        if (Sources.FirstOrDefault(source => source.App == app) is not { IsAvailable: true })
        {
            return false;
        }

        if (ticked ? _ticked.Add(app) : _ticked.Remove(app))
        {
            Raise();
        }

        return true;
    }

    public void Choose(SetupOrigin origin)
    {
        if (Step == SetupStep.Origin)
        {
            GoTo(origin == SetupOrigin.OtherApp ? SetupStep.Import : SetupStep.FirstConnection);
        }
    }

    public void Advance()
    {
        if (Step != SetupStep.Options)
        {
            GoTo(Step + 1);
        }
    }

    public void Back()
    {
        if (_history.TryPop(out var previous))
        {
            _moved = true;
            Step = previous;
            Raise();
        }
    }

    public void Record(FirstConnectionChoice choice)
    {
        _moved = true;
        Recorded = choice;
        Raise();
    }

    // One connection written from a picked export makes the whole ending a selection.
    public void AddImported(ForeignImportOutcome outcome, ImportSource source)
    {
        ArgumentNullException.ThrowIfNull(outcome);
        if (source == ImportSource.FileOrLink && outcome.ConnectionIds.Count > 0)
        {
            _importSource = ImportSource.FileOrLink;
        }

        foreach (var id in outcome.ConnectionIds.Where(id => !_imported.Contains(id)))
        {
            _imported.Add(id);
        }
    }

    // Finish and Skip alike: a recorded first connection wins, then the ids every import of the guide wrote.
    public SetupEnding End() => Recorded switch
    {
        FirstConnectionChoice.NewConnection => SetupEnding.NewConnection.Instance,
        FirstConnectionChoice.Sample => SetupEnding.Sample.Instance,
        _ => Handoff(_imported, _importSource),
    };

    private void GoTo(SetupStep step)
    {
        _moved = true;
        _history.Push(Step);
        Step = step;
        Raise();
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}
