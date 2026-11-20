using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ForeignImportFormTests
{
    private static readonly Guid Saved = Guid.Parse("8c1d7f3e-4b0a-4d6e-9a51-2f6c0e7b9d10");

    [Theory]
    [InlineData(ForeignApp.DBeaver, true, ForeignPasswordNote.DecryptedWhileReading, true)]
    [InlineData(ForeignApp.DataGrip, true, ForeignPasswordNote.PasswordFile, true)]
    [InlineData(ForeignApp.Dbx, true, ForeignPasswordNote.KeyInCredentialManager, true)]
    [InlineData(ForeignApp.TablePlus, false, ForeignPasswordNote.SystemStore, false)]
    [InlineData(ForeignApp.Navicat, true, ForeignPasswordNote.DecryptedWhileReading, false)]
    public async Task TheOptionsFollowWhereTheChosenAppKeepsItsPasswordsAndQueries(
        ForeignApp app, bool passwords, ForeignPasswordNote note, bool queries)
    {
        var form = await Loaded(new FakeImporter(Sources(tablePlusFound: true)));

        Assert.True(form.Choose(app));

        Assert.Equal(new ForeignPasswordOption(passwords, passwords, note), form.Passwords);
        Assert.Equal(queries, form.Queries.Offered);
        Assert.Equal(queries, form.Queries.Checked);
        Assert.Equal(form.Sources.Single(source => source.App == app).SavedQuerySupport, form.Queries.Support);
    }

    [Fact]
    public async Task TheFirstAppFoundIsChosenAndOneNotFoundCannotBe()
    {
        var form = await Loaded(new FakeImporter(Sources()));

        Assert.Equal(ForeignImportStep.Choosing, form.Step);
        Assert.Equal(ForeignApp.DBeaver, form.Chosen?.App);
        Assert.False(form.Choose(ForeignApp.TablePlus));
        Assert.False(form.Choose(ForeignApp.BeekeeperStudio));
        Assert.Equal(ForeignApp.DBeaver, form.Chosen?.App);
        Assert.True(form.CanContinue);
        Assert.Equal<ForeignSourceNote>(
            [
                ForeignSourceNote.NotFound,
                ForeignSourceNote.Found,
                ForeignSourceNote.Found,
                ForeignSourceNote.NotFound,
                ForeignSourceNote.PicksFile,
                ForeignSourceNote.Found,
            ],
            form.Sources.Select(ForeignImportForm.NoteFor));
    }

    [Fact]
    public async Task AppsThatCannotBeLookedForLeaveAnEmptyListAndNothingToContinue()
    {
        var importer = new FakeImporter(Sources()) { SourcesFailure = Error("storage.io") };

        var form = await Loaded(importer);

        Assert.Empty(form.Sources);
        Assert.Equal("storage.io", form.SourcesError?.Code);
        Assert.Null(form.Chosen);
        Assert.False(form.CanContinue);
        Assert.False(form.Passwords.Offered);
        Assert.False(form.Queries.Offered);
    }

    [Fact]
    public async Task AKeychainAppIsStillAskedForPasswordsSoTheReviewSaysTheyStayedBehind()
    {
        var importer = new FakeImporter(Sources(tablePlusFound: true)) { Review = Review() };
        var form = await Loaded(importer);

        form.Choose(ForeignApp.TablePlus);
        form.SetPasswords(false);
        await form.ReadAsync(null, TestContext.Current.CancellationToken);

        var read = Assert.Single(importer.Reads);
        Assert.Equal(ForeignApp.TablePlus, read.App);
        Assert.Null(read.File);
        Assert.Equal(new ForeignImportRequest(true, false), read.Request);
    }

    [Fact]
    public async Task TheBoxesKeepTheirAnswersWhileAnAppThatCannotHonourThemIsChosen()
    {
        var importer = new FakeImporter(Sources()) { Review = Review() };
        var form = await Loaded(importer);

        form.SetPasswords(false);
        form.SetQueries(false);
        form.Choose(ForeignApp.Navicat);
        form.SetQueries(true);
        form.Choose(ForeignApp.DBeaver);

        Assert.False(form.Passwords.Checked);
        Assert.False(form.Queries.Checked);
        Assert.Equal(new ForeignImportRequest(false, false), form.Request());
        form.SetPasswords(true);
        Assert.Equal(new ForeignImportRequest(true, false), form.Request());
    }

    [Fact]
    public async Task DbxPasswordsAreReadOnlyWhenAskedForWhileAnUnreadableStoreIsStillAskedAbout()
    {
        var form = await Loaded(new FakeImporter(Sources(tablePlusFound: true)));

        form.Choose(ForeignApp.Dbx);
        form.SetPasswords(false);
        Assert.Equal(new ForeignImportRequest(false, true), form.Request());

        form.Choose(ForeignApp.TablePlus);
        Assert.Equal(new ForeignImportRequest(true, false), form.Request());
    }

    [Fact]
    public async Task AnAppReadFromAnExportNeedsTheFileAndOthersNeverTakeOne()
    {
        var importer = new FakeImporter(Sources()) { Review = Review() };
        var form = await Loaded(importer);
        var token = TestContext.Current.CancellationToken;

        form.Choose(ForeignApp.Navicat);
        Assert.False(await form.ReadAsync(null, token));
        Assert.Empty(importer.Reads);
        Assert.True(await form.ReadAsync(@"C:\exports\connections.ncx", token));

        var second = await Loaded(importer);
        Assert.True(await second.ReadAsync(@"C:\exports\connections.ncx", token));

        Assert.Equal<(ForeignApp, string?, ForeignImportRequest)>(
            [
                (ForeignApp.Navicat, @"C:\exports\connections.ncx", new ForeignImportRequest(true, false)),
                (ForeignApp.DBeaver, null, new ForeignImportRequest(true, true)),
            ],
            importer.Reads);
    }

    [Fact]
    public async Task AReviewListsEachRowWithItsChecksAndASummary()
    {
        var form = await Read(Review());

        Assert.Equal(ForeignImportStep.Reviewing, form.Step);
        Assert.Equal(ForeignApp.DBeaver, form.ReviewedApp);
        Assert.Equal(ForeignPasswordOutcome.Read, form.PasswordOutcome);
        Assert.Equal<bool>([true, false, false], form.Connections.Select(line => line.Selected));
        Assert.Equal<bool>([true, true, false], form.Connections.Select(line => line.Selectable));
        Assert.Equal<ForeignQueryAvailability?>(
            [ForeignQueryAvailability.Available, ForeignQueryAvailability.ConnectionSkipped],
            form.SavedQueries.Select(line => line.Availability));
        Assert.Equal(new ForeignImportSummary(1, 3, 1, 2), form.Summary);
        Assert.True(form.CanImport);
    }

    [Fact]
    public async Task AMatchedRowAsksHowToResolveOnlyWhileItIsChecked()
    {
        var form = await Read(Review());
        var before = form.Connections[1];

        form.SetSelected("billing", true);
        var chosen = form.Connections[1];
        var replaced = form.Resolve("billing", new ForeignResolution.Replace(Saved));

        Assert.False(before.ShowsResolution);
        Assert.False(before.CanResolve);
        Assert.True(chosen.ShowsResolution);
        Assert.True(chosen.CanResolve);
        Assert.Equal<ForeignResolution>(
            [ForeignResolution.AddCopy.Instance, new ForeignResolution.Replace(Saved)],
            chosen.Offered);
        Assert.Equal(ForeignResolution.AddCopy.Instance, chosen.Resolution);
        Assert.True(replaced);
        Assert.Equal(new ForeignResolution.Replace(Saved), form.Connections[1].Resolution);
        Assert.False(form.Connections[0].ShowsResolution);
    }

    [Fact]
    public async Task EachCheckIsCountedAgainAndAQueryFollowsItsConnection()
    {
        var form = await Read(Review());

        form.SetSelected("billing", true);
        Assert.Equal(new ForeignImportSummary(2, 3, 2, 2), form.Summary);

        form.SetIncluded("query-1", false);
        Assert.Equal(new ForeignImportSummary(2, 3, 1, 2), form.Summary);

        form.SetSelected("orders", false);
        form.SetSelected("billing", false);
        Assert.Equal(new ForeignImportSummary(0, 3, 0, 2), form.Summary);
        Assert.False(form.SavedQueries[1].Importable);
        Assert.False(form.CanImport);
        Assert.Null(await form.ImportAsync());
    }

    [Theory]
    [InlineData("foreign_import.file_not_found", ForeignReadFailureKind.NotFound)]
    [InlineData("foreign_import.nothing_found", ForeignReadFailureKind.NothingFound)]
    [InlineData("foreign_import.unreadable", ForeignReadFailureKind.Unreadable)]
    [InlineData("foreign_import.parse", ForeignReadFailureKind.Unreadable)]
    [InlineData("foreign_import.unsupported_format", ForeignReadFailureKind.Unreadable)]
    [InlineData("storage.corrupt", ForeignReadFailureKind.Library)]
    [InlineData("ffi.panicked", ForeignReadFailureKind.Other)]
    public async Task AFailedReadReturnsToTheAppsWithWhyAndAnotherAppClearsIt(string code, ForeignReadFailureKind kind)
    {
        var failure = Error(code);
        var form = await Loaded(new FakeImporter(Sources()) { Failure = failure });

        Assert.False(await form.ReadAsync(null, TestContext.Current.CancellationToken));

        Assert.Equal(ForeignImportStep.Choosing, form.Step);
        Assert.Equal(new ForeignReadFailure(ForeignApp.DBeaver, kind, failure), form.Failure);
        form.Choose(ForeignApp.DataGrip);
        Assert.Null(form.Failure);
    }

    [Fact]
    public async Task ACancelledReadReturnsToTheAppsWithNoFailure()
    {
        var form = await Loaded(new FakeImporter(Sources()) { Cancels = true });

        Assert.False(await form.ReadAsync(null, TestContext.Current.CancellationToken));

        Assert.Equal(ForeignImportStep.Choosing, form.Step);
        Assert.Null(form.Failure);
    }

    [Fact]
    public async Task AReadThatLandsAfterTheDialogClosedIsLetGo()
    {
        var pending = new TaskCompletionSource<IForeignReview>();
        var form = await Loaded(new FakeImporter(Sources()) { Pending = pending });
        var review = Review();

        var reading = form.ReadAsync(null, TestContext.Current.CancellationToken);
        Assert.Equal(ForeignImportStep.Reading, form.Step);
        form.Dispose();
        pending.SetResult(review);

        Assert.False(await reading);
        Assert.True(review.Disposed);
        Assert.Empty(form.Connections);
    }

    [Fact]
    public async Task AnImportSaysWhatLandedAndWhatDidNotInOrder()
    {
        var review = Review();
        review.Outcome = new ForeignImportOutcome(2, 1, 1, 3, 0, 1);
        var form = await Read(review);

        var ending = await form.ImportAsync();

        Assert.NotNull(ending);
        Assert.Equal<ForeignImportSentence>(
            [
                new ForeignImportSentence(ForeignImportPart.Connections, 2),
                new ForeignImportSentence(ForeignImportPart.QueriesAdded, 3),
                new ForeignImportSentence(ForeignImportPart.QueriesNotAdded, 1),
                new ForeignImportSentence(ForeignImportPart.PasswordsNotKept, 1),
            ],
            ending.Sentences);
        Assert.True(ending.Wrote);
        Assert.True(ending.Partial);
        Assert.False(ending.Nothing);
        Assert.Equal(1, review.Applies);
        Assert.Equal(ForeignImportStep.Done, form.Step);
        Assert.False(form.CanImport);
        Assert.Null(await form.ImportAsync());
    }

    [Fact]
    public async Task AnImportThatWroteNothingSaysSo()
    {
        var form = await Read(Review());

        var ending = await form.ImportAsync();

        Assert.Equal<ForeignImportSentence>([new ForeignImportSentence(ForeignImportPart.Nothing)], ending?.Sentences);
        Assert.True(ending?.Nothing);
        Assert.False(ending?.Partial);
    }

    [Fact]
    public async Task ALibraryChangedWhileDecidingRefusesAndAsksToImportAgain()
    {
        var review = Review();
        review.Refusal = Error(ForeignImportEnding.OutdatedCode);
        var form = await Read(review);

        var ending = await form.ImportAsync();

        Assert.NotNull(ending);
        Assert.Equal<ForeignImportSentence>([new ForeignImportSentence(ForeignImportPart.Outdated)], ending.Sentences);
        Assert.True(ending.Outdated);
        Assert.False(ending.Wrote);
        Assert.Equal(ForeignImportStep.Done, form.Step);
    }

    [Fact]
    public async Task AnotherRefusalCarriesItsError()
    {
        var review = Review();
        review.Refusal = Error("storage.io");
        var form = await Read(review);

        var ending = await form.ImportAsync();

        Assert.Equal<ForeignImportSentence>([new ForeignImportSentence(ForeignImportPart.Failed)], ending?.Sentences);
        Assert.Equal("storage.io", ending?.Error?.Code);
        Assert.False(ending?.Outdated);
    }

    private static async Task<ForeignImportForm> Loaded(FakeImporter importer)
    {
        var form = new ForeignImportForm(importer);
        await form.LoadAsync();
        return form;
    }

    private static async Task<ForeignImportForm> Read(FakeReview review)
    {
        var form = await Loaded(new FakeImporter(Sources()) { Review = review });
        Assert.True(await form.ReadAsync(null, TestContext.Current.CancellationToken));
        return form;
    }

    private static CoreError Error(string code) => new(code, [code], code, null, null);

    // The apps the core lists on Windows, in its order.
    private static IReadOnlyList<ForeignSource> Sources(bool tablePlusFound = false) =>
    [
        Source(
            ForeignApp.TablePlus,
            tablePlusFound,
            ForeignPasswordSource.Keychain,
            ForeignSavedQuerySupport.GlobalFolder),
        Source(ForeignApp.DBeaver, true, ForeignPasswordSource.AppFiles, ForeignSavedQuerySupport.Scripts),
        Source(ForeignApp.DataGrip, true, ForeignPasswordSource.Keychain, ForeignSavedQuerySupport.Consoles),
        Source(
            ForeignApp.BeekeeperStudio,
            false,
            ForeignPasswordSource.AppFiles,
            ForeignSavedQuerySupport.GlobalFolder),
        new ForeignSource(
            ForeignApp.Navicat,
            "Navicat",
            true,
            0,
            0,
            ["ncx"],
            ForeignPasswordSource.AppFiles,
            ForeignSavedQuerySupport.NotInExport),
        Source(ForeignApp.Dbx, true, ForeignPasswordSource.Keychain, ForeignSavedQuerySupport.Scripts),
    ];

    private static ForeignSource Source(
        ForeignApp app,
        bool found,
        ForeignPasswordSource passwords,
        ForeignSavedQuerySupport queries) =>
        new(app, app.ToString(), found, found ? 2 : 0, found ? 1 : 0, [], passwords, queries);

    // Orders imports, billing matches a saved connection, ledger is an engine no driver opens.
    private static FakeReview Review() => new(
        [
            Row("orders", "Orders", "postgres"),
            Row("billing", "Billing", "mysql") with { Duplicate = new ExistingConnection(Saved, "billing") },
            Row("ledger", "Ledger", "oracle") with
            {
                Connection = null,
                Notes = [new ForeignRowNote.UnsupportedEngine("Oracle")],
            },
        ],
        [
            new ForeignQueryRow("query-1", "Daily orders", "orders", "Orders", 24),
            new ForeignQueryRow("query-2", "Invoices", "billing", "Billing", 31),
        ]);

    private static ForeignConnectionRow Row(string reference, string name, string engine) => new(
        reference,
        name,
        engine,
        new SavedConnection(
            null, name, engine, $"{reference}.example.com", 5432, reference, "deploy", TlsSettings.Disabled),
        [],
        null,
        [],
        1,
        false);
}

internal sealed class FakeImporter(IReadOnlyList<ForeignSource> sources) : IForeignImporter
{
    public List<(ForeignApp App, string? File, ForeignImportRequest Request)> Reads { get; } = [];

    public FakeReview? Review { get; init; }

    public CoreError? SourcesFailure { get; init; }

    public CoreError? Failure { get; init; }

    public bool Cancels { get; init; }

    public TaskCompletionSource<IForeignReview>? Pending { get; init; }

    public Task<IReadOnlyList<ForeignSource>> GetSourcesAsync() => SourcesFailure is { } failure
        ? Task.FromException<IReadOnlyList<ForeignSource>>(new TableProException(failure))
        : Task.FromResult(sources);

    public Task<IForeignReview> ReadAsync(
        ForeignApp app,
        string? file,
        ForeignImportRequest request,
        CancellationToken cancellationToken)
    {
        Reads.Add((app, file, request));
        if (Pending is { } pending)
        {
            return pending.Task;
        }

        if (Failure is { } failure)
        {
            return Task.FromException<IForeignReview>(new TableProException(failure));
        }

        if (Cancels)
        {
            return Task.FromCanceled<IForeignReview>(new CancellationToken(canceled: true));
        }

        return Task.FromResult<IForeignReview>(Review ?? throw new InvalidOperationException("No review to read."));
    }
}

// The core's rules in small: a matched or unopenable row starts unchecked, and a query imports with its connection.
internal sealed class FakeReview : IForeignReview
{
    private readonly HashSet<string> _selected;
    private readonly HashSet<string> _excluded = [];
    private readonly Dictionary<string, ForeignResolution> _resolutions = [];

    public FakeReview(IReadOnlyList<ForeignConnectionRow> connections, IReadOnlyList<ForeignQueryRow> queries)
    {
        Connections = connections;
        SavedQueries = queries;
        _selected = [.. connections
            .Where(row => row.Connection is not null && row.Duplicate is null)
            .Select(row => row.Reference)];
    }

    public ForeignApp App => ForeignApp.DBeaver;

    public ForeignPasswordOutcome Passwords => ForeignPasswordOutcome.Read;

    public IReadOnlyList<ForeignConnectionRow> Connections { get; }

    public IReadOnlyList<ForeignQueryRow> SavedQueries { get; }

    public ForeignImportOutcome Outcome { get; set; } = new(0, 0, 0, 0, 0, 0);

    public CoreError? Refusal { get; set; }

    public int Applies { get; private set; }

    public bool Disposed { get; private set; }

    public ForeignImportChoices Choices()
    {
        List<ForeignConnectionChoice> connections = [.. Connections.Select(row => new ForeignConnectionChoice(
            row.Reference,
            _selected.Contains(row.Reference),
            _resolutions.GetValueOrDefault(row.Reference) ?? Offered(row)[0],
            Offered(row)))];
        List<ForeignQueryChoice> queries = [.. SavedQueries.Select(query =>
        {
            var availability = query.Connection is null ? ForeignQueryAvailability.NoConnection
                : _selected.Contains(query.Connection) ? ForeignQueryAvailability.Available
                : ForeignQueryAvailability.ConnectionSkipped;
            return new ForeignQueryChoice(
                query.Reference,
                availability,
                availability == ForeignQueryAvailability.Available && !_excluded.Contains(query.Reference));
        })];
        return new ForeignImportChoices(
            connections,
            queries,
            connections.Any(choice => choice.Selected) || queries.Any(choice => choice.Included));
    }

    public void SetSelected(string reference, bool selected)
    {
        if (selected)
        {
            _selected.Add(reference);
        }
        else
        {
            _selected.Remove(reference);
        }
    }

    public bool Resolve(string reference, ForeignResolution resolution)
    {
        if (Connections.FirstOrDefault(row => row.Reference == reference) is not { } row
            || !Offered(row).Contains(resolution))
        {
            return false;
        }

        _resolutions[reference] = resolution;
        return true;
    }

    public void SetIncluded(string reference, bool included)
    {
        if (included)
        {
            _excluded.Remove(reference);
        }
        else
        {
            _excluded.Add(reference);
        }
    }

    public Task<ForeignImportOutcome> ApplyAsync()
    {
        Applies++;
        return Refusal is { } refusal
            ? Task.FromException<ForeignImportOutcome>(new TableProException(refusal))
            : Task.FromResult(Outcome);
    }

    public void Dispose() => Disposed = true;

    private static List<ForeignResolution> Offered(ForeignConnectionRow row) => row.Duplicate is { } existing
        ? [ForeignResolution.AddCopy.Instance, new ForeignResolution.Replace(existing.Id)]
        : [ForeignResolution.Add.Instance];
}
