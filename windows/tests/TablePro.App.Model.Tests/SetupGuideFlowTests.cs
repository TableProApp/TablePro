using TablePro.Interop;

namespace TablePro.App.Model.Tests;

// The Windows rows of core 0057's gate table, the step order and how the guide ends.
public sealed class SetupGuideFlowTests
{
    public static TheoryData<string, SetupGate, bool> GateRows => new()
    {
        { "G1 launch, read, empty, not seen", new SetupGate(false, true, 0, false), true },
        { "G2 launch, read, empty, seen", new SetupGate(false, true, 0, true), false },
        { "G3 launch, read, a connection or the sample", new SetupGate(false, true, 1, false), false },
        { "G4 launch, library not read", new SetupGate(false, false, 0, false), false },
        { "G5 launch, read, groups only", new SetupGate(false, true, 0, false), true },
        { "G6 Help > Setup Guide, seen, connections", new SetupGate(true, true, 4, true), true },
        { "G6 Help > Setup Guide, library not read", new SetupGate(true, false, 0, false), true },
        { "G8 launch, read, empty, a launched file waiting", new SetupGate(false, true, 0, false, LaunchWork: true), false },
    };

    [Theory]
    [MemberData(nameof(GateRows))]
    public void TheGateFollowsTheTable(string row, SetupGate gate, bool shows)
    {
        Assert.True(SetupGuide.ShouldShow(gate) == shows, row);
    }

    [Fact]
    public void TheStepsRunInOrderAndBackStartsFromTheSecondShown()
    {
        var guide = new SetupGuide(new FakeImporter([]));
        var steps = new List<SetupStep> { guide.Step };
        guide.Changed += (_, _) => steps.Add(guide.Step);

        Assert.False(guide.CanGoBack);
        guide.Choose(SetupOrigin.OtherApp);
        guide.Advance();
        guide.Advance();
        guide.Advance();
        Assert.True(guide.CanGoBack);
        guide.Back();

        Assert.Equal(
            [
                SetupStep.Origin,
                SetupStep.Import,
                SetupStep.FirstConnection,
                SetupStep.Options,
                SetupStep.FirstConnection,
            ],
            steps);
    }

    [Fact]
    public void ANewUserSkipsTheImportStepAndBackReturnsToTheOrigin()
    {
        var guide = new SetupGuide(new FakeImporter([]));

        guide.Choose(SetupOrigin.New);
        Assert.Equal(SetupStep.FirstConnection, guide.Step);
        guide.Back();

        Assert.Equal(SetupStep.Origin, guide.Step);
        Assert.False(guide.CanGoBack);
    }

    [Fact]
    public async Task TheProbeFindsAnAppWithDataAndLeavesOutAPickedFile()
    {
        var found = new FakeImporter([Source(ForeignApp.Navicat, picksFile: true), Source(ForeignApp.DBeaver)]);
        var onlyFile = new FakeImporter([Source(ForeignApp.Navicat, picksFile: true)]);
        var withApp = new SetupGuide(found);
        var withFile = new SetupGuide(onlyFile);

        await withApp.ProbeAsync(SetupGuide.ProbeLimit);
        await withFile.ProbeAsync(SetupGuide.ProbeLimit);

        Assert.Equal(["DBeaver"], withApp.Found);
        Assert.Empty(withFile.Found);
        Assert.Equal(SetupOrigin.New, withFile.Origin);
        Assert.Equal([ForeignScanDepth.Presence], found.Scans);
    }

    [Fact]
    public async Task TheProbeSelectsAnotherAppAndNamesTheAppsFoundWithoutLeavingTheOrigin()
    {
        var guide = new SetupGuide(new FakeImporter(
        [
            Source(ForeignApp.TablePlus, available: false),
            Source(ForeignApp.DBeaver),
            Source(ForeignApp.Navicat, picksFile: true),
            Source(ForeignApp.Dbx),
        ]));
        var changes = 0;
        guide.Changed += (_, _) => changes++;

        await guide.ProbeAsync(SetupGuide.ProbeLimit);

        Assert.Equal(1, changes);
        Assert.Equal(SetupStep.Origin, guide.Step);
        Assert.False(guide.CanGoBack);
        Assert.Equal(SetupOrigin.OtherApp, guide.Origin);
        Assert.Equal(["DBeaver", "Dbx"], guide.Found);

        guide.Choose(guide.Origin);
        Assert.Equal(SetupStep.Import, guide.Step);
    }

    [Fact]
    public async Task AChoiceTheUserMadeBeforeTheProbeAnsweredIsKept()
    {
        var importer = new FakeImporter([Source(ForeignApp.DBeaver)]);
        var file = new SetupGuide(importer);
        var backToNew = new SetupGuide(importer);
        var wentOn = new SetupGuide(importer);
        var defaultClicked = new SetupGuide(importer);
        file.Select(SetupOrigin.File);
        backToNew.Select(SetupOrigin.File);
        backToNew.Select(SetupOrigin.New);
        wentOn.Choose(SetupOrigin.New);
        defaultClicked.Select(SetupOrigin.New);

        foreach (var guide in new[] { file, backToNew, wentOn, defaultClicked })
        {
            await guide.ProbeAsync(SetupGuide.ProbeLimit);
            Assert.Equal(["DBeaver"], guide.Found);
        }

        Assert.Equal(SetupOrigin.File, file.Origin);
        Assert.Equal(SetupOrigin.New, backToNew.Origin);
        Assert.Equal(SetupStep.FirstConnection, wentOn.Step);
        wentOn.Back();
        Assert.Equal(SetupOrigin.New, wentOn.Origin);
        // Only a change is a choice, so the default card selected again leaves the probe to decide.
        Assert.Equal(SetupOrigin.OtherApp, defaultClicked.Origin);
        file.Choose(SetupOrigin.File);
        Assert.Equal(SetupStep.Origin, file.Step);
    }

    [Fact]
    public async Task AnAnswerPastTheLimitOrAFailureDoesNothing()
    {
        var slow = new FakeImporter([]) { PendingSources = new TaskCompletionSource<IReadOnlyList<ForeignSource>>() };
        var failing = new FakeImporter([])
        {
            SourcesFailure = new CoreError("storage.io", ["storage.io"], "io", null, null),
        };
        var late = new SetupGuide(slow);
        var failed = new SetupGuide(failing);
        var changes = 0;
        late.Changed += (_, _) => changes++;
        failed.Changed += (_, _) => changes++;

        await late.ProbeAsync(TimeSpan.FromMilliseconds(20));
        await failed.ProbeAsync(SetupGuide.ProbeLimit);
        slow.PendingSources.SetResult([Source(ForeignApp.DBeaver)]);
        await Task.Yield();

        Assert.Equal(0, changes);
        foreach (var guide in new[] { late, failed })
        {
            Assert.Equal(SetupStep.Origin, guide.Step);
            Assert.Equal(SetupOrigin.New, guide.Origin);
            Assert.Empty(guide.Found);
        }
    }

    [Fact]
    public async Task EnteringImportReadsTheCountsAndTicksWhatTheCoreTicks()
    {
        var importer = new FakeImporter(
        [
            Source(ForeignApp.TablePlus, ticked: false),
            Source(ForeignApp.DBeaver),
            Source(ForeignApp.Navicat, picksFile: true),
            Source(ForeignApp.Dbx),
            Source(ForeignApp.DataGrip, available: false),
        ]);
        var guide = new SetupGuide(importer);
        guide.Choose(SetupOrigin.OtherApp);

        await guide.LoadSourcesAsync();

        Assert.Equal([ForeignScanDepth.Inventory], importer.Scans);
        Assert.Equal([ForeignApp.DBeaver, ForeignApp.Dbx], guide.Queue.Select(source => source.App));
        Assert.True(guide.SetTicked(ForeignApp.TablePlus, true));
        Assert.False(guide.SetTicked(ForeignApp.DataGrip, true));
        Assert.Equal(
            [ForeignApp.TablePlus, ForeignApp.DBeaver, ForeignApp.Dbx],
            guide.Queue.Select(source => source.App));
    }

    [Fact]
    public void ARecordedFirstConnectionRunsAtTheEndAndWinsOverImports()
    {
        var guide = new SetupGuide(new FakeImporter([]));
        guide.AddImported(Outcome(Guid.NewGuid()), ImportSource.ThisComputer);

        guide.Record(FirstConnectionChoice.Sample);
        Assert.Equal(SetupEnding.Sample.Instance, guide.End());
        guide.Record(FirstConnectionChoice.NewConnection);
        Assert.Equal(SetupEnding.NewConnection.Instance, guide.End());
    }

    [Fact]
    public void TheIdsEveryImportWroteDecideTheEnding()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        var none = new SetupGuide(new FakeImporter([]));
        var one = new SetupGuide(new FakeImporter([]));
        var several = new SetupGuide(new FakeImporter([]));

        one.AddImported(Outcome(first), ImportSource.ThisComputer);
        several.AddImported(Outcome(first), ImportSource.ThisComputer);
        several.AddImported(Outcome(), ImportSource.ThisComputer);
        several.AddImported(Outcome(second, first), ImportSource.ThisComputer);

        Assert.Equal(SetupEnding.Stay.Instance, none.End());
        Assert.Equal(new SetupEnding.Open(first), one.End());
        Assert.Equal(new SetupEnding.SelectInLibrary([first, second]), several.End());
    }

    [Fact]
    public void AConnectionFromAPickedExportMakesTheGuideSelectInsteadOfOpen()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        var picked = new SetupGuide(new FakeImporter([]));
        var mixed = new SetupGuide(new FakeImporter([]));
        var emptyExport = new SetupGuide(new FakeImporter([]));

        picked.AddImported(Outcome(first), ImportSource.FileOrLink);
        mixed.AddImported(Outcome(first), ImportSource.ThisComputer);
        mixed.AddImported(Outcome(second), ImportSource.FileOrLink);
        emptyExport.AddImported(Outcome(first), ImportSource.ThisComputer);
        emptyExport.AddImported(Outcome(), ImportSource.FileOrLink);

        Assert.Equal(new SetupEnding.SelectInLibrary([first]), picked.End());
        Assert.Equal(new SetupEnding.SelectInLibrary([first, second]), mixed.End());
        Assert.Equal(new SetupEnding.Open(first), emptyExport.End());
    }

    [Fact]
    public void AConnectionsFileImportSelectsWhatItWroteAndNeverConnects()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();

        Assert.Equal(
            SetupEnding.Stay.Instance,
            SetupGuide.Handoff(new ImportSummary(0, 0, []).ConnectionIds, ImportSource.FileOrLink));
        Assert.Equal(
            new SetupEnding.SelectInLibrary([first]),
            SetupGuide.Handoff(new ImportSummary(1, 0, [first]).ConnectionIds, ImportSource.FileOrLink));
        Assert.Equal(
            new SetupEnding.SelectInLibrary([first, second]),
            SetupGuide.Handoff(new ImportSummary(1, 1, [first, second]).ConnectionIds, ImportSource.FileOrLink));
    }

    [Fact]
    public void AnImportFromAnotherAppOpensOneAndSelectsSeveral()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();

        Assert.Equal(SetupEnding.Stay.Instance, SetupGuide.Handoff(Outcome().ConnectionIds, ImportSource.ThisComputer));
        Assert.Equal(
            new SetupEnding.Open(first),
            SetupGuide.Handoff(Outcome(first).ConnectionIds, ImportSource.ThisComputer));
        Assert.Equal(
            new SetupEnding.SelectInLibrary([first, second]),
            SetupGuide.Handoff(Outcome(first, second).ConnectionIds, ImportSource.ThisComputer));
    }

    private static ForeignImportOutcome Outcome(params Guid[] ids) => new(ids.Length, 0, 0, 0, 0, 0, ids);

    private static ForeignSource Source(
        ForeignApp app, bool available = true, bool picksFile = false, bool? ticked = null) => new(
        app,
        app.ToString(),
        available ? ForeignSourceAvailability.Available.Instance : ForeignSourceAvailability.NotFound.Instance,
        available ? 3 : 0,
        0,
        picksFile ? ["ncx"] : [],
        ForeignPasswordSource.AppFiles,
        ForeignSavedQuerySupport.Scripts,
        ForeignPasswordOffer.DecryptedWhileReading,
        true,
        ticked ?? (available && !picksFile),
        false);
}
