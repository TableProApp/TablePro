namespace TablePro.Interop.Tests;

public sealed class ConnectionUrlTests
{
    [Fact]
    public void AUrlsPasswordComesThroughButItsTextShowsOnlyThatOneIsSet()
    {
        var parsed = TableProCore.ParseConnectionUrl("postgresql://app:hunter2@db/shop");
        var shown = parsed.ToString();

        Assert.Equal("hunter2", parsed.Password);
        Assert.Equal("app", parsed.UserName);
        Assert.Equal("shop", parsed.Database);
        Assert.DoesNotContain("hunter2", shown, StringComparison.Ordinal);
        Assert.StartsWith("ParsedConnectionUrl { EngineId = postgres, Host = db, ", shown, StringComparison.Ordinal);
        Assert.Contains("UserName = app, Password = [REDACTED], Database = shop, ", shown, StringComparison.Ordinal);
    }

    [Fact]
    public void ConnectionSecretsSayWhichAreSetButNotWhatTheyAre()
    {
        var secrets = new ConnectionSecrets(DatabasePassword: "hunter2", SshPassphrase: string.Empty);

        Assert.Equal(
            "ConnectionSecrets { DatabasePassword = [REDACTED], SshPassword = , SshPassphrase = [REDACTED] }",
            secrets.ToString());
    }
}
