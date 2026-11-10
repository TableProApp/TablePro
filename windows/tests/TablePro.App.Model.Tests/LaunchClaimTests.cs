namespace TablePro.App.Model.Tests;

public sealed class LaunchClaimTests
{
    [Fact]
    public void AProcessThatHoldsTheKeyStartsWithoutHandingOver()
    {
        var handed = 0;

        var starts = LaunchClaim.StartsHere<Owner>(
            () => null, _ => Count(ref handed, HandOverResult.Taken), _ => { });

        Assert.True(starts);
        Assert.Equal(0, handed);
    }

    [Fact]
    public void ALaunchTheRunningAppTookEnds() =>
        Assert.False(LaunchClaim.StartsHere(() => new Owner(), _ => HandOverResult.Taken, _ => { }));

    [Fact]
    public void ALaunchStartsItsOwnWindowWhenTheRunningAppGivesNoAnswer() =>
        Assert.True(LaunchClaim.StartsHere(() => new Owner(), _ => HandOverResult.NoAnswer, _ => { }));

    [Fact]
    public void ALaunchLooksAgainOnceTheOwnerExitedAndStartsWithTheKey()
    {
        var owners = new Queue<Owner?>([new Owner(), null]);
        var handed = 0;

        var starts = LaunchClaim.StartsHere(
            owners.Dequeue, _ => Count(ref handed, HandOverResult.OwnerExited), _ => { });

        Assert.True(starts);
        Assert.Equal(1, handed);
    }

    [Fact]
    public void ALaunchStartsAfterItsAttemptsWhenEveryOwnerExits()
    {
        var handed = 0;

        var starts = LaunchClaim.StartsHere(
            () => new Owner(), _ => Count(ref handed, HandOverResult.OwnerExited), _ => { });

        Assert.True(starts);
        Assert.Equal(LaunchClaim.Attempts, handed);
    }

    [Fact]
    public void ALaunchStartsAndReportsWhenTheGuardFails()
    {
        var failure = new InvalidOperationException("The shared memory could not be opened.");
        Exception? reported = null;

        var starts = LaunchClaim.StartsHere<Owner>(
            () => throw failure, _ => HandOverResult.Taken, exception => reported = exception);

        Assert.True(starts);
        Assert.Same(failure, reported);
    }

    [Fact]
    public void AKeyNobodyHoldsAnyMoreHasNoOwner() =>
        Assert.Null(LaunchClaim.OwnerOf<Owner>(null, _ => false));

    [Fact]
    public void ThisProcessIsNeverItsOwnOwner() =>
        Assert.Null(LaunchClaim.OwnerOf(new Owner(), _ => true));

    [Fact]
    public void AnotherProcessHoldingTheKeyIsTheOwner()
    {
        var other = new Owner();

        Assert.Same(other, LaunchClaim.OwnerOf(other, _ => false));
    }

    [Fact]
    public void AWaitThatTimedOutIsNoAnswerWhateverTheRedirectDidLater() =>
        Assert.Equal(HandOverResult.NoAnswer, LaunchClaim.ReadWait(timedOut: true, Task.CompletedTask));

    [Fact]
    public void AFinishedRedirectIsTaken() =>
        Assert.Equal(HandOverResult.Taken, LaunchClaim.ReadWait(timedOut: false, Task.CompletedTask));

    [Fact]
    public void AFailedRedirectIsAnOwnerThatExited()
    {
        var failed = Task.FromException(new InvalidOperationException("The owner is gone."));

        Assert.Equal(HandOverResult.OwnerExited, LaunchClaim.ReadWait(timedOut: false, failed));
    }

    [Fact]
    public void AWaitThatEndedOnTheOwnersExitWithTheRedirectPendingIsAnOwnerThatExited()
    {
        var pending = new TaskCompletionSource().Task;

        Assert.Equal(HandOverResult.OwnerExited, LaunchClaim.ReadWait(timedOut: false, pending));
    }

    private static HandOverResult Count(ref int handed, HandOverResult result)
    {
        handed++;
        return result;
    }

    private sealed class Owner
    {
    }
}
