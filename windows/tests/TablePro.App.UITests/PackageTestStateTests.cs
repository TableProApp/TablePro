namespace TablePro.App.UITests;

public sealed class PackageTestStateTests
{
    [Fact]
    public void ExistingStateIsPreserved()
    {
        var folder = Directory.CreateTempSubdirectory("tablepro-package-test-");
        try
        {
            var library = Directory.CreateDirectory(Path.Combine(folder.FullName, "library"));
            var connections = Path.Combine(library.FullName, "connections.json");
            var session = Path.Combine(folder.FullName, "session.json");
            File.WriteAllText(connections, "saved connections");
            File.WriteAllText(session, "saved session");

            Assert.Throws<InvalidOperationException>(() => new PackageTestState().Prepare(folder.FullName));

            Assert.Equal("saved connections", File.ReadAllText(connections));
            Assert.Equal("saved session", File.ReadAllText(session));
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }

    [Fact]
    public void OnlyTheProcessThatClaimedEmptyStateCanResetIt()
    {
        var folder = Directory.CreateTempSubdirectory("tablepro-package-test-");
        try
        {
            var state = new PackageTestState();
            state.Prepare(folder.FullName);
            File.WriteAllText(Path.Combine(folder.FullName, "settings.json"), "test settings");
            Directory.CreateDirectory(Path.Combine(folder.FullName, "library"));

            Assert.Throws<InvalidOperationException>(() => new PackageTestState().Prepare(folder.FullName));
            state.Prepare(folder.FullName);

            Assert.Empty(folder.EnumerateFileSystemInfos());
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }
}
