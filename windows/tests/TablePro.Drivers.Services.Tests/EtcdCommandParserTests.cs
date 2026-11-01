using TablePro.Drivers.Etcd;

namespace TablePro.Drivers.Services.Tests;

public sealed class EtcdCommandParserTests
{
    [Fact]
    public void GetReadsEveryFlag()
    {
        var get = Assert.IsType<EtcdGet>(EtcdCommandParser.Parse("get /app/ --prefix --limit 10 --keys-only --order=descend --sort-by MOD --rev 7"));

        Assert.Equal(new EtcdGet("/app/", null, true, false, 10, true, false, "DESCEND", "MOD", 7), get);
    }

    [Fact]
    public void GetTakesARangeEndAndFromKey()
    {
        Assert.Equal(new EtcdGet("a", "c"), EtcdCommandParser.Parse("get a c"));
        Assert.Equal(new EtcdGet("a", FromKey: true), EtcdCommandParser.Parse("GET a --from-key"));
        Assert.Equal(new EtcdGet("a", CountOnly: true), EtcdCommandParser.Parse("get a --count-only"));
    }

    [Fact]
    public void PutKeepsQuotedValuesWhole()
    {
        var put = Assert.IsType<EtcdPut>(EtcdCommandParser.Parse("put \"/app/my key\" 'hello world' --lease=694d77aa9e38260f"));

        Assert.Equal("/app/my key", put.Key);
        Assert.Equal("hello world", put.Value);
        Assert.Equal(0x694d77aa9e38260f, put.Lease);
    }

    [Fact]
    public void PutReadsEscapesInsideQuotes()
    {
        var put = Assert.IsType<EtcdPut>(EtcdCommandParser.Parse("put k \"line1\\nline2 \\\"q\\\"\""));

        Assert.Equal("line1\nline2 \"q\"", put.Value);
    }

    [Fact]
    public void DelReadsPrefixFromKeyAndRange()
    {
        Assert.Equal(new EtcdDelete("/app/", Prefix: true), EtcdCommandParser.Parse("del /app/ --prefix"));
        Assert.Equal(new EtcdDelete("a", "z"), EtcdCommandParser.Parse("delete a z"));
        Assert.Equal(new EtcdDelete("a", FromKey: true), EtcdCommandParser.Parse("del a --from-key"));
    }

    [Fact]
    public void WatchHasADefaultAndABoundedTimeout()
    {
        Assert.Equal(new EtcdWatch("k", false, EtcdCommandParser.DefaultWatchSeconds), EtcdCommandParser.Parse("watch k"));
        Assert.Equal(new EtcdWatch("k", true, 2.5), EtcdCommandParser.Parse("watch k --prefix --timeout 2.5s"));
    }

    [Fact]
    public void LeaseSubcommandsAreRead()
    {
        Assert.Equal(new EtcdLeaseGrant(60), EtcdCommandParser.Parse("lease grant 60"));
        Assert.Equal(new EtcdLeaseRevoke(0x1f), EtcdCommandParser.Parse("lease revoke 0x1f"));
        Assert.Equal(new EtcdLeaseTimeToLive(42, true), EtcdCommandParser.Parse("lease timetolive 42 --keys"));
        Assert.Equal(new EtcdLeaseList(), EtcdCommandParser.Parse("lease list"));
        Assert.Equal(new EtcdLeaseKeepAlive(0xab), EtcdCommandParser.Parse("lease keep-alive ab"));
    }

    [Fact]
    public void ClusterAndAdminCommandsAreRead()
    {
        Assert.Equal(new EtcdMemberList(), EtcdCommandParser.Parse("member list"));
        Assert.Equal(new EtcdEndpointStatus(), EtcdCommandParser.Parse("endpoint status"));
        Assert.Equal(new EtcdEndpointHealth(), EtcdCommandParser.Parse("ENDPOINT HEALTH"));
        Assert.Equal(new EtcdCompaction(100, true), EtcdCommandParser.Parse("compaction 100 --physical"));
        Assert.Equal(new EtcdAuthToggle(true), EtcdCommandParser.Parse("auth enable"));
        Assert.Equal(new EtcdAuthToggle(false), EtcdCommandParser.Parse("auth disable"));
        Assert.Equal(new EtcdUserAdd("bob", "pw"), EtcdCommandParser.Parse("user add bob pw"));
        Assert.Equal(new EtcdUserDelete("bob"), EtcdCommandParser.Parse("user delete bob"));
        Assert.Equal(new EtcdUserList(), EtcdCommandParser.Parse("user list"));
        Assert.Equal(new EtcdUserGrantRole("bob", "admin"), EtcdCommandParser.Parse("user grant-role bob admin"));
        Assert.Equal(new EtcdUserRevokeRole("bob", "admin"), EtcdCommandParser.Parse("user revoke-role bob admin"));
        Assert.Equal(new EtcdRoleAdd("admin"), EtcdCommandParser.Parse("role add admin"));
        Assert.Equal(new EtcdRoleDelete("admin"), EtcdCommandParser.Parse("role delete admin"));
        Assert.Equal(new EtcdRoleList(), EtcdCommandParser.Parse("role list"));
    }

    [Theory]
    [InlineData("10", 10)]
    [InlineData("0x0a", 10)]
    [InlineData("694d77aa9e38260f", 0x694d77aa9e38260f)]
    public void LeaseIdsAreHexOrDecimal(string text, long expected)
    {
        Assert.Equal(expected, EtcdCommandParser.ParseLeaseId(text));
        Assert.Equal("0x" + expected.ToString("x", System.Globalization.CultureInfo.InvariantCulture), EtcdCommandParser.LeaseHex(expected));
    }

    [Theory]
    [InlineData("", "Empty")]
    [InlineData("frobnicate x", "Unknown command")]
    [InlineData("get", "get needs a key")]
    [InlineData("get k --limit", "--limit needs a value")]
    [InlineData("get k --limit ten", "whole number")]
    [InlineData("get k --order sideways", "ASCEND or DESCEND")]
    [InlineData("get k --sort-by size", "KEY, VERSION")]
    [InlineData("get k --prefix --from-key", "cannot be used together")]
    [InlineData("put k", "needs a key and a value")]
    [InlineData("put k a b", "quote a value")]
    [InlineData("put k v --lease=zz", "Invalid lease ID")]
    [InlineData("del", "del needs a key")]
    [InlineData("watch", "watch needs a key")]
    [InlineData("watch k --timeout soon", "number of seconds")]
    [InlineData("watch k --timeout 9999", "between 0 and")]
    [InlineData("lease", "lease needs a subcommand")]
    [InlineData("lease grant", "TTL")]
    [InlineData("lease grant -5", "TTL")]
    [InlineData("lease revoke", "needs a lease ID")]
    [InlineData("lease renew 1", "Unknown command: lease renew")]
    [InlineData("member", "member needs a subcommand")]
    [InlineData("member add x", "Unknown command: member add")]
    [InlineData("endpoint hashkv", "Unknown command: endpoint hashkv")]
    [InlineData("compaction", "needs a revision")]
    [InlineData("auth", "auth needs a subcommand")]
    [InlineData("user add", "needs a user name")]
    [InlineData("user grant-role bob", "needs a user name and a role")]
    [InlineData("role", "role needs a subcommand")]
    [InlineData("role add", "needs a role name")]
    [InlineData("put k \"open", "never closed")]
    public void RefusesWhatItCannotRead(string command, string message)
    {
        var error = Assert.Throws<EtcdCommandException>(() => EtcdCommandParser.Parse(command));

        Assert.Contains(message, error.Message, StringComparison.OrdinalIgnoreCase);
    }
}
