namespace TablePro.Interop.Tests;

public sealed class KeymapTests
{
    private static string Chord(KeymapBinding binding) =>
        (binding.Control ? "ctrl+" : "") + (binding.Shift ? "shift+" : "") + (binding.Alt ? "alt+" : "")
        + (binding.Command ? "cmd+" : "") + binding.Key;

    [Fact]
    public void APresetGivesTheWindowsRowsWhateverHostRunsTheTest()
    {
        var rows = TableProCore.KeymapPreset("dbeaver", KeymapPlatform.Windows);

        Assert.Contains(rows, row => row.Action == "executeQuery" && Chord(row) == "ctrl+enter");
        Assert.Contains(rows, row => row.Action == "executeAllStatements" && Chord(row) == "ctrl+shift+enter");
        Assert.Contains(rows, row => row.Action == "discardChanges" && Chord(row) == "ctrl+r");
        Assert.DoesNotContain(rows, row => row.Command);
    }

    [Fact]
    public void MacRowsUseCommandAndLeaveOutWhatTheMacAppHasNoCommandFor()
    {
        var rows = TableProCore.KeymapPreset("dbeaver", KeymapPlatform.MacOs);

        Assert.Contains(rows, row => row.Action == "executeQuery" && Chord(row) == "cmd+enter");
        Assert.DoesNotContain(rows, row => row.Action == "discardChanges");
    }

    [Fact]
    public void RowsReadFromMacKeysAreMarkedDerivedOnWindowsOnly()
    {
        Assert.All(TableProCore.KeymapPreset("tableplus", KeymapPlatform.Windows), row => Assert.True(row.Derived));
        Assert.All(TableProCore.KeymapPreset("tableplus", KeymapPlatform.MacOs), row => Assert.False(row.Derived));
    }

    [Fact]
    public void WindowsOffersEveryPresetButTheMacOnlyApp()
    {
        var presets = TableProCore.KeymapPresets(KeymapPlatform.Windows);

        Assert.Equal(
            ["tableplus", "dbeaver", "datagrip", "beekeeperstudio", "navicat", "dbx"],
            presets.Select(preset => preset.Id));
        Assert.Equal(new KeymapPresetInfo("tableplus", "TablePlus"), presets[0]);
    }

    [Fact]
    public void APresetOffItsPlatformOrUnknownThrowsWithItsCode()
    {
        var offPlatform = Assert.Throws<TableProException>(
            () => TableProCore.KeymapPreset("sequelace", KeymapPlatform.Windows));
        var unknown = Assert.Throws<TableProException>(() => TableProCore.KeymapPreset("vscode", KeymapPlatform.Linux));

        Assert.Equal("keymap.not_on_platform", offPlatform.Code);
        Assert.Equal("keymap.unknown_preset", unknown.Code);
    }
}
