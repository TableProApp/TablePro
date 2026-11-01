using TablePro.Core.Connections;

namespace TablePro.Ssh.Tests;

public sealed class SshArgumentsTests
{
    [Fact]
    public void AgentLoginBuildsABatchModeForward()
    {
        var args = Build(new SshTunnelSettings { Enabled = true, Host = "bastion.example.com", Username = "ops" }, answersPrompts: false);

        Assert.Equal(
            [
                "-N", "-T", "-n",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=15",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-o", "PermitLocalCommand=no",
                "-L", "127.0.0.1:50123:db.internal:5432",
                "-p", "22",
                "-l", "ops",
                "--", "bastion.example.com",
            ],
            args);
    }

    [Fact]
    public void PrivateKeyLimitsSshToThatKey()
    {
        var args = Build(new SshTunnelSettings
        {
            Enabled = true,
            Host = "bastion",
            AuthMethod = SshAuthMethod.PrivateKey,
            PrivateKeyPath = @"C:\Users\Jane Doe\.ssh\id_ed25519",
        }, answersPrompts: false);

        AssertPair(args, "-i", @"C:\Users\Jane Doe\.ssh\id_ed25519");
        AssertOption(args, "IdentitiesOnly=yes");
        AssertOption(args, "BatchMode=yes");
        Assert.DoesNotContain("-l", args);
    }

    [Fact]
    public void KeyWithAPassphraseLeavesBatchModeOff()
    {
        var args = Build(new SshTunnelSettings { Enabled = true, Host = "bastion", AuthMethod = SshAuthMethod.PrivateKey, PrivateKeyPath = "key" }, answersPrompts: true);

        AssertOption(args, "BatchMode=no");
    }

    [Fact]
    public void PasswordLoginPrefersPasswordAndAsksOnce()
    {
        var args = Build(new SshTunnelSettings { Enabled = true, Host = "bastion", Port = 2222, AuthMethod = SshAuthMethod.Password }, answersPrompts: true);

        AssertOption(args, "BatchMode=no");
        AssertOption(args, "PreferredAuthentications=password,keyboard-interactive,publickey");
        AssertOption(args, "NumberOfPasswordPrompts=1");
        AssertPair(args, "-p", "2222");
        Assert.DoesNotContain("-i", args);
    }

    [Fact]
    public void JumpHostsAreTrimmedAndJoined()
    {
        var args = Build(new SshTunnelSettings { Enabled = true, Host = "db-bastion", JumpHosts = " me@edge:2200 ,, ops@[fe80::1]:22 " }, answersPrompts: false);

        AssertPair(args, "-J", "me@edge:2200,ops@[fe80::1]:22");
        Assert.Equal("db-bastion", args[^1]);
        Assert.Equal("--", args[^2]);
    }

    [Fact]
    public void Ipv6DatabaseHostsAreBracketedInTheForward()
    {
        var args = SshArguments.Build(new SshTunnelSettings { Enabled = true, Host = "bastion" }, "2001:db8::5", 3306, 40000, 10, 15, answersPrompts: false);

        AssertPair(args, "-L", "127.0.0.1:40000:[2001:db8::5]:3306");
        AssertOption(args, "ConnectTimeout=10");
        AssertOption(args, "ServerAliveInterval=15");
    }

    [Theory]
    [InlineData("-oProxyCommand=calc", null, null)]
    [InlineData("bastion host", null, null)]
    [InlineData("bastion", "-oProxyCommand=calc", null)]
    [InlineData("bastion", "ops", "edge;calc")]
    [InlineData("bastion", "ops", "-J evil")]
    [InlineData("", null, null)]
    public void ValuesSshWouldReadAsOptionsAreRejected(string host, string? user, string? jumps)
    {
        var settings = new SshTunnelSettings { Enabled = true, Host = host, Username = user, JumpHosts = jumps };

        Assert.Throws<ArgumentException>(() => Build(settings, answersPrompts: false));
    }

    [Fact]
    public void PortsOutsideTheValidRangeAreRejected()
    {
        var settings = new SshTunnelSettings { Enabled = true, Host = "bastion" };

        Assert.Throws<ArgumentOutOfRangeException>(() => SshArguments.Build(settings, "db", 0, 40000, 10, 30, answersPrompts: false));
        Assert.Throws<ArgumentOutOfRangeException>(() => SshArguments.Build(settings, "db", 5432, 70000, 10, 30, answersPrompts: false));
    }

    [Theory]
    [InlineData(null, null)]
    [InlineData("  ", null)]
    [InlineData(" a , b ", "a,b")]
    [InlineData("a,,b,", "a,b")]
    public void JumpHostListsNormalize(string? input, string? expected) =>
        Assert.Equal(expected, SshArguments.NormalizeJumpHosts(input));

    private static IReadOnlyList<string> Build(SshTunnelSettings settings, bool answersPrompts) =>
        SshArguments.Build(settings, "db.internal", 5432, 50123, 15, 30, answersPrompts);

    private static void AssertOption(IReadOnlyList<string> args, string option) => AssertPair(args, "-o", option);

    private static void AssertPair(IReadOnlyList<string> args, string flag, string value)
    {
        for (var i = 0; i < args.Count - 1; i++)
        {
            if (args[i] == flag && args[i + 1] == value)
            {
                return;
            }
        }

        Assert.Fail($"Expected \"{flag} {value}\" in: {string.Join(' ', args)}");
    }
}
