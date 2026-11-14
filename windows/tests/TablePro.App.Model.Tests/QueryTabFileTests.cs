using System.Text;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryTabFileTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-sqlfile-").FullName;
    private readonly FakeSession _session = new();
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();
    private readonly FakeFileView _files;

    public QueryTabFileTests()
    {
        _files = new FakeFileView(_view);
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public void AFileTabIsNamedForItsFileAndCleanUntilItsTextChanges()
    {
        var tab = Open("report.sql", "select 1;");
        var changes = 0;
        tab.StateChanged += (_, _) => changes++;

        Assert.Equal("report.sql", tab.Title);
        Assert.False(tab.IsDirty);
        Assert.False(tab.HasUnsavedChanges);

        _view.WholeText = "select 2;";
        tab.TextEdited();
        Assert.True(tab.IsDirty);
        Assert.True(tab.HasUnsavedChanges);
        Assert.Equal(1, changes);

        _view.WholeText = "select 1;";
        tab.TextEdited();
        Assert.False(tab.IsDirty);
        Assert.Equal(2, changes);
    }

    [Fact]
    public async Task SaveWritesTheTextBackInTheEncodingTheFileHad()
    {
        var path = Write("latin.sql", Encoding.Latin1.GetBytes("select 'caf\u00e9';"));
        var tab = Open(path);
        var saved = new List<string>();
        tab.FileSaved += (_, file) => saved.Add(file);
        _view.WholeText = "select 'na\u00efve caf\u00e9';";
        tab.TextEdited();

        Assert.True(await tab.SaveAsync());

        Assert.Equal(Encoding.Latin1.GetBytes("select 'na\u00efve caf\u00e9';"), File.ReadAllBytes(path));
        Assert.False(tab.IsDirty);
        Assert.Equal<string>([path], saved);
        Assert.Empty(_files.Picks);
    }

    [Fact]
    public async Task SavingATabWithNoFileAsksWhereAndWritesUtf8()
    {
        var path = Path.Combine(_directory, "new.sql");
        _files.Picked = path;
        var tab = Tab();
        _view.WholeText = "select '\u2713';";

        Assert.True(await tab.SaveAsync());

        Assert.Equal<(string, string?)>([("Query 1.sql", null)], _files.Picks);
        Assert.Equal(Encoding.UTF8.GetBytes("select '\u2713';"), File.ReadAllBytes(path));
        Assert.Equal(path, tab.FilePath);
        Assert.Equal("new.sql", tab.Title);
        Assert.Equal(path, tab.Snapshot().FilePath);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public async Task SaveAsWritesUtf8WithoutAMarkAndTheTabKeepsTheNewFile()
    {
        byte[] wide = [.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes("select 1;")];
        var original = Write("wide.sql", wide);
        var copy = Path.Combine(_directory, "copy.sql");
        _files.Picked = copy;
        var tab = Open(original);

        Assert.True(await tab.SaveAsAsync());
        _view.WholeText = "select 2;";
        Assert.True(await tab.SaveAsync());

        Assert.Equal<(string, string?)>([("wide.sql", _directory)], _files.Picks);
        Assert.Equal(Encoding.UTF8.GetBytes("select 2;"), File.ReadAllBytes(copy));
        Assert.Equal(wide, File.ReadAllBytes(original));
        Assert.Equal(copy, tab.FilePath);
    }

    [Fact]
    public async Task ADismissedPickerSavesNothing()
    {
        var tab = Tab();

        Assert.False(await tab.SaveAsync());

        Assert.Null(tab.FilePath);
        Assert.Single(_files.Picks);
        Assert.Empty(Directory.GetFiles(_directory));
    }

    [Fact]
    public async Task AScratchTabClosesWithoutAsking()
    {
        var tab = Tab();
        _view.WholeText = "select 2;";

        Assert.True(await tab.ConfirmCloseAsync(offerSave: true));

        Assert.False(tab.HasUnsavedChanges);
        Assert.Equal(0, _files.ClosesAsked);
    }

    [Fact]
    public async Task ClosingACleanFileTabAsksNothing()
    {
        var tab = Open("clean.sql", "select 1;");

        Assert.True(await tab.ConfirmCloseAsync(offerSave: true));

        Assert.Equal(0, _files.ClosesAsked);
    }

    [Fact]
    public async Task ClosingADirtyFileTabSavesWhenAskedTo()
    {
        var tab = Open("edit.sql", "select 1;");
        _view.WholeText = "select 2;";

        Assert.True(await tab.ConfirmCloseAsync(offerSave: true));

        Assert.Equal(1, _files.ClosesAsked);
        Assert.Equal("select 2;", File.ReadAllText(Path.Combine(_directory, "edit.sql")));
    }

    [Theory]
    [InlineData(SaveBeforeClose.DontSave, true)]
    [InlineData(SaveBeforeClose.Cancel, false)]
    public async Task ClosingADirtyFileTabWithoutSavingLeavesTheFile(SaveBeforeClose answer, bool closes)
    {
        _files.CloseAnswer = answer;
        var tab = Open("edit.sql", "select 1;");
        _view.WholeText = "select 2;";

        Assert.Equal(closes, await tab.ConfirmCloseAsync(offerSave: true));

        Assert.Equal("select 1;", File.ReadAllText(Path.Combine(_directory, "edit.sql")));
    }

    [Fact]
    public async Task ASaveThatFailsOnClosingKeepsTheTabAndTheFile()
    {
        var path = Write("latin.sql", Encoding.Latin1.GetBytes("select 'caf\u00e9';"));
        var tab = Open(path);
        _view.WholeText = "select '\U0001F600';";

        Assert.False(await tab.ConfirmCloseAsync(offerSave: true));

        var failure = Assert.IsType<SqlFileEncodingException>(Assert.Single(_files.Failures));
        Assert.Equal("\U0001F600", failure.Character);
        Assert.Equal(Encoding.Latin1.GetBytes("select 'caf\u00e9';"), File.ReadAllBytes(path));
        Assert.True(tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task ACancelledSaveAsOnClosingKeepsTheTab()
    {
        var tab = Open("moved.sql", "select 1;");
        File.Delete(Path.Combine(_directory, "moved.sql"));
        _view.WholeText = "select 2;";

        Assert.False(await tab.ConfirmCloseAsync(offerSave: true));

        Assert.Single(_files.Picks);
        Assert.True(tab.HasUnsavedChanges);
    }

    [Theory]
    [InlineData(SaveOverChange.Cancel, "select 'theirs';", "select 'mine';")]
    [InlineData(SaveOverChange.Overwrite, "select 'mine';", "select 'mine';")]
    [InlineData(SaveOverChange.Reload, "select 'theirs';", "select 'theirs';")]
    public async Task SavingOverAFileChangedOnDiskAsksFirst(SaveOverChange answer, string onDisk, string inTab)
    {
        var tab = Open("shared.sql", "select 1;");
        File.WriteAllText(Path.Combine(_directory, "shared.sql"), "select 'theirs';");
        _view.WholeText = "select 'mine';";
        _files.OverAnswer = answer;

        Assert.Equal(answer == SaveOverChange.Overwrite, await tab.SaveAsync());

        Assert.Equal(1, _files.OversAsked);
        Assert.Equal(onDisk, File.ReadAllText(Path.Combine(_directory, "shared.sql")));
        Assert.Equal(inTab, _view.WholeText);
    }

    [Fact]
    public async Task AFileRewrittenWithTheSameTextSavesWithoutAsking()
    {
        var path = Write("same.sql", Encoding.UTF8.GetBytes("select 1;"));
        var tab = Open(path);
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(5));
        _view.WholeText = "select 2;";

        Assert.True(await tab.SaveAsync());

        Assert.Equal(0, _files.OversAsked);
        Assert.Equal("select 2;", File.ReadAllText(path));
    }

    [Fact]
    public async Task AChangeOnDiskShowsTheBarAndReloadTakesTheFilesText()
    {
        var tab = Open("live.sql", "select 1;");
        _view.WholeText = "select 'mine';";
        tab.TextEdited();
        File.WriteAllText(Path.Combine(_directory, "live.sql"), "select 'theirs';");

        await tab.CheckDiskAsync();
        Assert.Equal<DiskChange>([DiskChange.Changed], _files.Changes);

        Assert.True(await tab.ReloadAsync());

        Assert.Equal("select 'theirs';", _view.WholeText);
        Assert.False(tab.IsDirty);
        Assert.Equal(DiskChange.None, _files.Changes[^1]);
        await tab.CheckDiskAsync();
        Assert.Equal(DiskChange.None, _files.Changes[^1]);
    }

    [Fact]
    public async Task AnUnchangedFileShowsNoBar()
    {
        var tab = Open("still.sql", "select 1;");

        await tab.CheckDiskAsync();

        Assert.Equal<DiskChange>([DiskChange.None], _files.Changes);
    }

    [Fact]
    public async Task AClosedBarStaysClosedUntilTheFileChangesAgain()
    {
        var path = Path.Combine(_directory, "live.sql");
        var tab = Open("live.sql", "select 1;");
        File.WriteAllText(path, "select 22;");
        await tab.CheckDiskAsync();
        tab.DiskChangeDismissed();

        await tab.CheckDiskAsync();
        Assert.Equal<DiskChange>([DiskChange.Changed], _files.Changes);

        File.WriteAllText(path, "select 333;");
        await tab.CheckDiskAsync();
        Assert.Equal<DiskChange>([DiskChange.Changed, DiskChange.Changed], _files.Changes);
    }

    [Fact]
    public async Task ADeletedFileShowsTheBarAndSaveGoesToSaveAs()
    {
        var tab = Open("gone.sql", "select 1;");
        File.Delete(Path.Combine(_directory, "gone.sql"));
        var moved = Path.Combine(_directory, "found.sql");
        _files.Picked = moved;

        await tab.CheckDiskAsync();
        Assert.Equal<DiskChange>([DiskChange.Gone], _files.Changes);

        Assert.True(await tab.SaveAsync());

        Assert.Equal<(string, string?)>([("gone.sql", _directory)], _files.Picks);
        Assert.Equal("select 1;", File.ReadAllText(moved));
        Assert.Equal(DiskChange.None, _files.Changes[^1]);
    }

    [Fact]
    public void ATabRestoredWithTheFilesTextIsClean()
    {
        var path = Write("kept.sql", Encoding.UTF8.GetBytes("select 1;"));
        _view.WholeText = "select 1;";

        var tab = Tab(path, SqlFile.Read(path));

        Assert.False(tab.IsDirty);
        Assert.Equal(path, tab.Snapshot().FilePath);
    }

    [Fact]
    public void ATabRestoredWithOtherTextThanItsFileHasUnsavedChanges()
    {
        var path = Write("kept.sql", Encoding.UTF8.GetBytes("select 1;"));
        _view.WholeText = "select 'typed before the restart';";

        var tab = Tab(path, SqlFile.Read(path));

        Assert.True(tab.IsDirty);
        Assert.True(tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task ATabRestoredOverAFileThatIsGoneKeepsItsTextAndSaysSo()
    {
        var tab = Tab(Path.Combine(_directory, "missing.sql"), null);

        Assert.True(tab.HasUnsavedChanges);
        Assert.Equal("missing.sql", tab.Title);
        await tab.CheckDiskAsync();
        Assert.Equal<DiskChange>([DiskChange.Gone], _files.Changes);
        Assert.Equal("select * from Artist", tab.Snapshot().Sql);
    }

    [Fact]
    public void ARelaunchShowsACleanTabsFileAsItIsNowAndKeepsUnsavedText()
    {
        var path = Write("report.sql", Encoding.UTF8.GetBytes("select 'written while closed';"));
        var stamp = SqlFile.Read(path).Stamp;
        var older = stamp with { LastWriteUtc = stamp.LastWriteUtc.AddMinutes(-5) };

        var clean = SqlFileOpening.Restored("select 1;", older, unsaved: false, () => SqlFile.Read(path));
        var same = SqlFileOpening.Restored("select 'mine';", stamp, unsaved: true, () => SqlFile.Read(path));
        var changed = SqlFileOpening.Restored("select 'mine';", older, unsaved: true, () => SqlFile.Read(path));
        var gone = SqlFileOpening.Restored("select 'mine';", stamp, unsaved: true, () => null);

        Assert.Equal(("select 'written while closed';", false), (clean.Text, clean.BaselineUnknown));
        Assert.Equal(("select 'mine';", false, stamp), (same.Text, same.BaselineUnknown, same.Baseline?.Stamp));
        Assert.Equal(("select 'mine';", true, older), (changed.Text, changed.BaselineUnknown, changed.Baseline?.Stamp));
        Assert.Equal(("select 'mine';", null), (gone.Text, gone.Baseline));
    }

    [Fact]
    public async Task UnsavedTextOverAFileWrittenWhileTheAppWasClosedAsksBeforeASave()
    {
        var path = Write("report.sql", Encoding.UTF8.GetBytes("select 'theirs';"));
        var older = SqlFile.Read(path).Stamp;
        older = older with { LastWriteUtc = older.LastWriteUtc.AddMinutes(-5) };
        var opening = SqlFileOpening.Restored("select 'mine';", older, unsaved: true, () => SqlFile.Read(path));
        _view.WholeText = opening.Text;
        var tab = new QueryTab(
            "report.sql",
            _session,
            _view,
            _results,
            DataModel.Relational,
            () => new AppSettings(),
            files: _files,
            filePath: path,
            onDisk: opening.Baseline,
            baselineUnknown: opening.BaselineUnknown);

        await tab.CheckDiskAsync();
        var saved = await tab.SaveAsync();

        Assert.False(saved);
        Assert.True(tab.IsDirty);
        Assert.Equal<DiskChange>([DiskChange.Changed], _files.Changes);
        Assert.Equal(1, _files.OversAsked);
        Assert.Equal("select 'theirs';", File.ReadAllText(path));
    }

    [Fact]
    public async Task ASnapshotMarksUnsavedTextUntilDontSaveLetsItGo()
    {
        _files.CloseAnswer = SaveBeforeClose.DontSave;
        var tab = Open("edit.sql", "select 1;");
        _view.WholeText = "select 2;";
        tab.TextEdited();

        var dirty = tab.Snapshot();
        Assert.True(await tab.ConfirmCloseAsync(offerSave: true));
        var discarded = tab.Snapshot();
        tab.TextEdited();
        var editedAgain = tab.Snapshot();

        Assert.True(dirty.FileUnsaved);
        Assert.True(dirty.HasRecoveredWork);
        Assert.NotNull(dirty.FileStamp);
        Assert.False(discarded.FileUnsaved);
        Assert.False(discarded.HasRecoveredWork);
        Assert.True(editedAgain.FileUnsaved);
    }

    private QueryTab Open(string name, string text) =>
        Open(Write(name, Encoding.UTF8.GetBytes(text)));

    // As the view opens a file: the editor shows the file's text.
    private QueryTab Open(string path)
    {
        var read = SqlFile.Read(path);
        _view.WholeText = read.Text;
        return Tab(path, read);
    }

    private QueryTab Tab(string? path = null, SqlFileRead? onDisk = null) => new(
        "Query 1",
        _session,
        _view,
        _results,
        DataModel.Relational,
        () => new AppSettings(),
        files: _files,
        filePath: path,
        onDisk: onDisk);

    private string Write(string name, byte[] bytes)
    {
        var path = Path.Combine(_directory, name);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private sealed class FakeFileView(FakeQueryView view) : IQueryFileView
    {
        public string? Picked { get; set; }

        public List<(string Name, string? Folder)> Picks { get; } = [];

        public SaveBeforeClose CloseAnswer { get; set; } = SaveBeforeClose.Save;

        public SaveOverChange OverAnswer { get; set; } = SaveOverChange.Cancel;

        public int ClosesAsked { get; private set; }

        public int OversAsked { get; private set; }

        public List<DiskChange> Changes { get; } = [];

        public List<Exception> Failures { get; } = [];

        public void ReplaceText(string text) => view.WholeText = text;

        public Task<string?> PickSavePathAsync(string suggestedName, string? folder)
        {
            Picks.Add((suggestedName, folder));
            return Task.FromResult(Picked);
        }

        public Task<SaveBeforeClose> AskSaveBeforeCloseAsync(string tab, bool offerSave)
        {
            ClosesAsked++;
            return Task.FromResult(CloseAnswer);
        }

        public Task<SaveOverChange> AskSaveOverChangeAsync(string path)
        {
            OversAsked++;
            return Task.FromResult(OverAnswer);
        }

        public void ShowDiskChange(DiskChange change) => Changes.Add(change);

        public Task ShowSaveFailedAsync(string path, Exception failure)
        {
            Failures.Add(failure);
            return Task.CompletedTask;
        }

        public Task ShowReloadFailedAsync(string path, Exception failure)
        {
            Failures.Add(failure);
            return Task.CompletedTask;
        }
    }
}
