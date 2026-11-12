namespace TablePro.App.Model.Tests;

public sealed class InstanceKeyTests
{
    [Fact]
    public void AFolderGivesOneKeyWhateverItsCaseOrTrailingSeparator() =>
        Assert.Equal(
            InstanceKey.For(@"C:\Users\Ada\AppData\Local\TablePro"),
            InstanceKey.For(@"c:\users\ada\appdata\local\tablepro\"));

    [Fact]
    public void TwoFoldersGiveTwoKeys() =>
        Assert.NotEqual(InstanceKey.For(@"C:\Data\One"), InstanceKey.For(@"C:\Data\Two"));

    [Fact]
    public void AKeyIsShortAndPlainHoweverLongTheFolder()
    {
        var key = InstanceKey.For(@"C:\" + string.Join('\\', Enumerable.Repeat("a folder name", 40)));

        Assert.Equal(InstanceKey.For(@"C:\a").Length, key.Length);
        Assert.Matches("^[A-Za-z0-9-]+$", key);
    }
}
