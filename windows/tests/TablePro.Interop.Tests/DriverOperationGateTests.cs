using TablePro.App.Services;

namespace TablePro.Interop.Tests;

public sealed class DriverOperationGateTests
{
    [Fact]
    public async Task ReloadAndRemoveCannotInterruptAnInstall()
    {
        var gate = new DriverOperationGate();
        var transitions = new List<bool>();
        var installed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reloaded = false;
        var removed = false;

        var install = gate.RunAsync(() => installed.Task, transitions.Add);
        await gate.RunAsync(() =>
        {
            reloaded = true;
            return Task.CompletedTask;
        }, transitions.Add);
        await gate.RunAsync(() =>
        {
            removed = true;
            return Task.CompletedTask;
        }, transitions.Add);

        Assert.False(reloaded);
        Assert.False(removed);
        Assert.True(gate.IsBusy);
        Assert.Equal([true], transitions);

        installed.SetResult();
        await install;

        Assert.False(gate.IsBusy);
        Assert.Equal([true, false], transitions);
    }

    [Fact]
    public async Task AFailedOperationClearsBusyAndAllowsTheNextOperation()
    {
        var gate = new DriverOperationGate();
        var transitions = new List<bool>();
        var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var install = gate.RunAsync(() => failed.Task, transitions.Add);

        failed.SetException(new IOException("The driver could not be read."));
        await Assert.ThrowsAsync<IOException>(() => install);

        Assert.False(gate.IsBusy);
        var reloaded = false;
        await gate.RunAsync(() =>
        {
            reloaded = true;
            return Task.CompletedTask;
        }, transitions.Add);

        Assert.True(reloaded);
        Assert.False(gate.IsBusy);
        Assert.Equal([true, false, true, false], transitions);
    }
}
