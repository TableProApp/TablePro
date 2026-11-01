using TablePro.Storage.Secrets;

namespace TablePro.Storage.Tests;

public sealed class SecretStoreTests
{
    [Fact]
    public void InMemoryStoreRoundTrips()
    {
        var store = new InMemorySecretStore();
        var key = SecretKeys.Connection(Guid.NewGuid());

        Assert.Null(store.Get(key));
        store.Set(key, "hunter2");
        Assert.Equal("hunter2", store.Get(key));
        store.Set(key, "changed");
        Assert.Equal("changed", store.Get(key));
        Assert.True(store.Delete(key));
        Assert.False(store.Delete(key));
        Assert.Null(store.Get(key));
    }

    [Fact]
    public void KeysNameTheKindOfSecret()
    {
        var id = Guid.Parse("6f9619ff-8b86-d011-b42d-00c04fc964ff");
        Assert.Equal("TablePro/connection/6f9619ff-8b86-d011-b42d-00c04fc964ff", SecretKeys.Connection(id));
        Assert.Equal("TablePro/ssh/6f9619ff-8b86-d011-b42d-00c04fc964ff", SecretKeys.Ssh(id));
        Assert.Equal("TablePro/ai/anthropic", SecretKeys.Ai("Anthropic"));
    }

    [Fact]
    public void CredentialManagerRoundTripsAndDeletes()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Skip("Credential Manager exists only on Windows.");
            return;
        }

        var store = new CredentialManagerSecretStore();
        var key = SecretKeys.Prefix + "test/" + Guid.NewGuid().ToString("N");
        const string Secret = "päss wörd \U0001F511 with spaces";
        try
        {
            Assert.Null(store.Get(key));

            store.Set(key, Secret);
            Assert.Equal(Secret, store.Get(key));

            store.Set(key, string.Empty);
            Assert.Equal(string.Empty, store.Get(key));

            Assert.True(store.Delete(key));
            Assert.Null(store.Get(key));
            Assert.False(store.Delete(key));
        }
        finally
        {
            store.Delete(key);
        }
    }

    [Fact]
    public void CredentialManagerRejectsASecretPastItsLimit()
    {
        if (!OperatingSystem.IsWindows())
        {
            Assert.Skip("Credential Manager exists only on Windows.");
            return;
        }

        var store = new CredentialManagerSecretStore();
        var key = SecretKeys.Prefix + "test/" + Guid.NewGuid().ToString("N");

        var tooLong = new string('x', 1281);
        try
        {
            store.Set(key, tooLong);
            Assert.Fail("A secret past Credential Manager's limit was accepted.");
        }
        catch (ArgumentException)
        {
        }

        Assert.Null(store.Get(key));
    }
}
