using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class AccountPanelTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 13, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void ANewMachineIsSignedOutAndSaysNothingAboutAnAccount()
    {
        var panel = AccountPanel.For(AccountStatus.SignedOut, signingIn: false);

        Assert.Equal(AccountStage.SignedOut, panel.Stage);
        Assert.Null(panel.Title);
        Assert.Null(panel.Notice);
        Assert.False(panel.IsPro);
        Assert.Empty(panel.LimitDevices);
    }

    [Fact]
    public void WaitingForTheBrowserIsItsOwnStage()
    {
        Assert.Equal(AccountStage.SigningIn, AccountPanel.For(AccountStatus.SignedOut, signingIn: true).Stage);
    }

    [Fact]
    public void ASignedInAccountIsNamedByItsNameAndElseItsEmail()
    {
        var named = AccountPanel.For(SignedIn(name: "Ada"), signingIn: false);
        var unnamed = AccountPanel.For(SignedIn(name: " "), signingIn: false);

        Assert.Equal(AccountStage.SignedIn, named.Stage);
        Assert.Equal("Ada", named.Title);
        Assert.Equal("ada@example.com", named.Email);
        Assert.Equal("ada@example.com", unnamed.Title);
        Assert.Null(named.Notice);
    }

    [Fact]
    public void ProIsTheSharedLinksFeature()
    {
        Assert.True(AccountPanel.For(SignedIn(features: ["shared_links"]), signingIn: false).IsPro);
        Assert.False(AccountPanel.For(SignedIn(features: ["team_library"]), signingIn: false).IsPro);
    }

    [Fact]
    public void EachProblemOfASignedInAccountIsANotice()
    {
        var expired = AccountPanel.For(SignedIn(problem: EntitlementProblem.Expired.Instance), signingIn: false);
        var failed = AccountPanel.For(
            SignedIn(problem: new EntitlementProblem.RefreshFailed("account.unreachable")),
            signingIn: false);
        var forgotten = AccountPanel.For(SignedIn(remembered: false), signingIn: false);

        Assert.Equal(new AccountNotice(AccountNoticeKind.Expired), expired.Notice);
        Assert.Equal(new AccountNotice(AccountNoticeKind.RefreshFailed, "account.unreachable"), failed.Notice);
        Assert.Equal(new AccountNotice(AccountNoticeKind.NotRemembered), forgotten.Notice);
    }

    [Fact]
    public void TheDeviceLimitListsThisMachineFirstThenTheMostRecentlySeen()
    {
        var old = Device("old", Now.AddDays(-9));
        var recent = Device("recent", Now.AddDays(-1));
        var here = Device("here", Now.AddDays(-30), thisMachine: true);

        var panel = AccountPanel.For(
            SignedIn(problem: new EntitlementProblem.DeviceLimitReached([old, recent, here])),
            signingIn: false);

        Assert.Equal(new AccountNotice(AccountNoticeKind.DeviceLimitReached), panel.Notice);
        Assert.Equal(["here", "recent", "old"], panel.LimitDevices.Select(device => device.Id));
    }

    [Fact]
    public void ADeviceWithAGoodOfflineFileOrThisMachineCannotBeRemoved()
    {
        Assert.True(AccountDevices.CanRemove(Device("a", Now), Now));
        Assert.False(AccountDevices.CanRemove(Device("b", Now, thisMachine: true), Now));
        Assert.False(AccountDevices.CanRemove(Device("c", Now) with { OfflineUntil = Now.AddDays(3) }, Now));
        Assert.True(AccountDevices.CanRemove(Device("d", Now) with { OfflineUntil = Now.AddDays(-1) }, Now));
    }

    [Fact]
    public void ARemovalThatThrewCountsAsDoneWhenTheDeviceIsNoLongerListed()
    {
        var other = Device("other", Now);

        Assert.Equal(DeviceRemoval.Removed, AccountDevices.Removal(true, null, "gone"));
        Assert.Equal(DeviceRemoval.RemovedNotRefreshed, AccountDevices.Removal(false, [other], "gone"));
        Assert.Equal(DeviceRemoval.NotRemoved, AccountDevices.Removal(false, [other, Device("gone", Now)], "gone"));
        Assert.Equal(DeviceRemoval.NotRemoved, AccountDevices.Removal(false, null, "gone"));
    }

    [Fact]
    public void TheDeviceLimitDialogStaysOnlyWhileTheLicenseIsPastItsLimit()
    {
        Assert.True(AccountDevices.PastLimit(SignedIn(problem: new EntitlementProblem.DeviceLimitReached([]))));
        Assert.False(AccountDevices.PastLimit(SignedIn()));
        Assert.False(AccountDevices.PastLimit(SignedIn(problem: EntitlementProblem.Expired.Instance)));
    }

    [Fact]
    public void AnOfflineFileIsNotASignIn()
    {
        var panel = AccountPanel.For(
            SignedIn(problem: EntitlementProblem.Expired.Instance) with { State = AccountState.Offline },
            signingIn: false);

        Assert.Equal(AccountStage.Offline, panel.Stage);
        Assert.Null(panel.Notice);
    }

    private static AccountStatus SignedIn(
        string? name = "Ada",
        IReadOnlyList<string>? features = null,
        EntitlementProblem? problem = null,
        bool remembered = true) =>
        new(
            AccountState.SignedIn,
            "acc_01",
            "ada@example.com",
            name,
            features ?? [],
            [],
            Now.AddDays(14),
            problem,
            remembered);

    private static AccountDevice Device(string id, DateTimeOffset seen, bool thisMachine = false) =>
        new(id, "windows", id, "1.0.0", "Windows 11", seen, null, null, thisMachine);
}
