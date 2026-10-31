namespace TablePro.Drivers.Beancount.Tests;

public sealed class IncludeResolverTests
{
    [Fact]
    public void SampleLedgerResolvesItsIncludesInReadOrder()
    {
        var graph = BeancountIncludeResolver.Resolve(Samples.Ledger);

        Assert.Equal(
            [
                Path.Combine(Samples.Directory, "main.beancount"),
                Path.Combine(Samples.Directory, "accounts.beancount"),
                Path.Combine(Samples.Directory, "transactions", "2026-01.beancount"),
            ],
            graph.SourceFiles);
        Assert.Contains(Path.Combine(Samples.Directory, "transactions"), graph.WatchedDirectories);
        Assert.Contains(Path.Combine(Samples.Directory, "docs", "statement.pdf"), graph.ReloadDependencies);
        Assert.True(graph.Lines[graph.SourceFiles[1]].Length >= 6);
    }

    [Fact]
    public void IncludesResolveRelativeToTheIncludingFile()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"years/2026.beancount\"\n");
        temp.Write(@"years\2026.beancount", "include \"../shared/accounts.beancount\" ; comment \"ignored\"\n");
        var shared = temp.Write(@"shared\accounts.beancount", "2026-01-01 open Assets:Cash\n");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Equal(3, graph.SourceFiles.Count);
        Assert.Equal(shared, graph.SourceFiles[2]);
    }

    [Fact]
    public void ForwardSlashesAndCaseDifferencesNameTheSameFile()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"Sub/A.beancount\"\ninclude \"sub/a.BEANCOUNT\"\n");
        temp.Write(@"sub\a.beancount", "2026-01-01 open Assets:Cash\n");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Equal(2, graph.SourceFiles.Count);
    }

    [Fact]
    public void GlobIncludesMatchWithinOneDirectoryAndSkipDotFiles()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"months/*.beancount\"\n");
        temp.Write(@"months\02.beancount", "");
        temp.Write(@"months\01.beancount", "");
        temp.Write(@"months\.hidden.beancount", "");
        temp.Write(@"months\notes.txt", "");
        temp.Write(@"months\deep\03.beancount", "");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Equal(["main.beancount", "01.beancount", "02.beancount"], graph.SourceFiles.Select(Path.GetFileName));
        Assert.Contains(Path.Combine(temp.Path, "months"), graph.WatchedDirectories);
        Assert.Contains(Path.Combine(temp.Path, "months", "deep"), graph.WatchedDirectories);
    }

    [Fact]
    public void DoubleStarGlobSpansDirectories()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"ledger/**/*.bean\"\n");
        temp.Write(@"ledger\top.bean", "");
        temp.Write(@"ledger\2026\q1\jan.bean", "");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Equal(["main.beancount", "jan.bean", "top.bean"], graph.SourceFiles.Select(Path.GetFileName));
    }

    [Fact]
    public void GlobUnderAMissingDirectoryWatchesTheNearestExistingParent()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"later/imports/*.beancount\"\n");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Single(graph.SourceFiles);
        Assert.Contains(temp.Path, graph.WatchedDirectories, StringComparer.OrdinalIgnoreCase);
    }

    [Fact]
    public void IncludeCycleIsReported()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"other.beancount\"\n");
        temp.Write("other.beancount", "include \"main.beancount\"\n");

        var error = Assert.Throws<BeancountException>(() => BeancountIncludeResolver.Resolve(main));

        Assert.Contains("include cycle", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void FileIncludedTwiceWithoutACycleIsReadOnce()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"a.beancount\"\ninclude \"b.beancount\"\n");
        temp.Write("a.beancount", "include \"common.beancount\"\n");
        temp.Write("b.beancount", "include \"common.beancount\"\n");
        temp.Write("common.beancount", "");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Equal(4, graph.SourceFiles.Count);
    }

    [Fact]
    public void MissingIncludeNamesTheFile()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", "include \"missing.beancount\"\n");

        var error = Assert.Throws<BeancountException>(() => BeancountIncludeResolver.Resolve(main));

        Assert.Contains("missing.beancount", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void DocumentsAreDependenciesUnderTheirFileAndEachDocumentsRoot()
    {
        using var temp = new TempDirectory();
        var main = temp.Write("main.beancount", """
            option "documents" "receipts"
            include "sub/docs.beancount"
            """);
        temp.Write(@"sub\docs.beancount", "2026-01-20 document Assets:Cash \"2026/statement.pdf\"\n");

        var graph = BeancountIncludeResolver.Resolve(main);

        Assert.Contains(Path.Combine(temp.Path, "sub", "2026", "statement.pdf"), graph.ReloadDependencies);
        Assert.Contains(Path.Combine(temp.Path, "receipts", "2026", "statement.pdf"), graph.ReloadDependencies);
    }

    [Fact]
    public void InvalidUtf8IsUnreadable()
    {
        using var temp = new TempDirectory();
        var main = Path.Combine(temp.Path, "main.beancount");
        File.WriteAllBytes(main, [0x32, 0x30, 0xC3, 0x28]);

        var error = Assert.Throws<BeancountException>(() => BeancountIncludeResolver.Resolve(main));

        Assert.StartsWith("Could not read", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(@"C:\l\*.bean", @"C:\l\a.bean", true)]
    [InlineData(@"C:\l\*.bean", @"C:\l\x\a.bean", false)]
    [InlineData(@"C:\l\**\*.bean", @"C:\l\a.bean", true)]
    [InlineData(@"C:\l\**\*.bean", @"C:\l\x\y\a.bean", true)]
    [InlineData(@"C:\l\20?[0-9].bean", @"C:\l\2026.bean", true)]
    [InlineData(@"C:\l\20?[0-9].bean", @"C:\l\202a.bean", false)]
    public void GlobTranslation(string pattern, string path, bool matches)
    {
        var regex = new System.Text.RegularExpressions.Regex(BeancountIncludeResolver.GlobRegex(pattern), System.Text.RegularExpressions.RegexOptions.IgnoreCase);

        Assert.Equal(matches, regex.IsMatch(path));
    }

    [Fact]
    public void SignaturesNoticeAnEditAndANewFileInAWatchedDirectory()
    {
        using var temp = new TempDirectory();
        var file = temp.Write("a.beancount", "one");
        string[] watched = [file, temp.Path];
        var before = SourceSignatures.Read(watched);

        Assert.True(SourceSignatures.Equal(before, SourceSignatures.Read(watched)));

        temp.Write("b.beancount", "");
        Assert.False(SourceSignatures.Equal(before, SourceSignatures.Read(watched)));

        var afterAdd = SourceSignatures.Read(watched);
        File.WriteAllText(file, "one two");
        Assert.False(SourceSignatures.Equal(afterAdd, SourceSignatures.Read(watched)));
    }
}
