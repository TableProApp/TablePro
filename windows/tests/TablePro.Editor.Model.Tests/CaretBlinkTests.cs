namespace TablePro.Editor.Model.Tests;

// Windows' defaults: a 530 ms blink and a 5,000 ms caret timeout.
public sealed class CaretBlinkTests
{
    private static readonly TimeSpan Blink = TimeSpan.FromMilliseconds(530);
    private static readonly TimeSpan Minute = TimeSpan.FromMinutes(1);

    [Fact]
    public void AnIdleMinuteBlinksForTheTimeoutThenLeavesTheCaretShown()
    {
        var clock = new ManualClock();
        var blink = Focused(clock);

        // Nine blinks fit in 5 s, then one draw leaves the caret shown; with no timeout it was 113.
        Assert.Equal(10, Run(blink, clock, Minute));
        Assert.False(blink.IsBlinking);
        Assert.True(blink.CaretVisible);
    }

    [Fact]
    public void WithNoTimeoutItBlinksTheWholeMinute()
    {
        var clock = new ManualClock();
        var blink = Focused(clock, timeout: TimeSpan.FromMilliseconds(-1));

        Assert.Equal(113, Run(blink, clock, Minute));
        Assert.True(blink.IsBlinking);
    }

    [Fact]
    public void InputAfterTheTimeoutBlinksAgain()
    {
        var clock = new ManualClock();
        var blink = Focused(clock);
        Run(blink, clock, Minute);

        blink.Restart();

        Assert.True(blink.IsBlinking);
        Assert.True(blink.CaretVisible);
        Assert.Equal(10, Run(blink, clock, Minute));
    }

    [Fact]
    public void InputWhileBlinkingStartsTheTimeoutAgain()
    {
        var clock = new ManualClock();
        var blink = Focused(clock);
        Assert.Equal(7, Run(blink, clock, TimeSpan.FromMilliseconds(4000)));

        blink.Restart();

        Assert.True(blink.CaretVisible);
        Assert.Equal(10, Run(blink, clock, Minute));
    }

    [Fact]
    public void AnInactiveWindowShowsNoCaretAndNeverBlinks()
    {
        var clock = new ManualClock();
        var blink = Focused(clock);

        Assert.True(blink.SetActive(false));

        Assert.False(blink.CaretVisible);
        Assert.False(blink.IsBlinking);
        Assert.Equal(0, Run(blink, clock, Minute));
    }

    [Fact]
    public void TheWindowActiveAgainShowsTheCaretAndBlinks()
    {
        var clock = new ManualClock();
        var blink = Focused(clock);
        blink.SetActive(false);
        Run(blink, clock, Minute);

        Assert.True(blink.SetActive(true));

        Assert.True(blink.CaretVisible);
        Assert.Equal(10, Run(blink, clock, Minute));
    }

    [Fact]
    public void LosingFocusHidesTheCaretAndStops()
    {
        var clock = new ManualClock();
        var blink = Focused(clock);

        Assert.True(blink.SetFocused(false));

        Assert.False(blink.CaretVisible);
        Assert.False(blink.IsBlinking);
        Assert.Equal(0, Run(blink, clock, Minute));
    }

    [Fact]
    public void BlinkingTurnedOffShowsASteadyCaret()
    {
        var clock = new ManualClock();
        var blink = new CaretBlink(clock) { Interval = TimeSpan.Zero };
        blink.SetFocused(true);

        Assert.True(blink.CaretVisible);
        Assert.False(blink.IsBlinking);
        Assert.Equal(0, Run(blink, clock, Minute));
    }

    private static CaretBlink Focused(ManualClock clock, TimeSpan? timeout = null)
    {
        var blink = new CaretBlink(clock) { Interval = Blink, Timeout = timeout ?? CaretBlink.DefaultTimeout };
        blink.SetFocused(true);
        return blink;
    }

    // A timer at the blink interval that nobody stopped; returns the ticks that changed the caret, each one a frame.
    private static int Run(CaretBlink blink, ManualClock clock, TimeSpan duration)
    {
        var changes = 0;
        for (var elapsed = Blink; elapsed <= duration; elapsed += Blink)
        {
            clock.Advance(Blink);
            if (blink.Tick())
            {
                changes++;
            }
        }
        return changes;
    }

    private sealed class ManualClock : TimeProvider
    {
        private long _milliseconds;

        public override long TimestampFrequency => 1000;

        public override long GetTimestamp() => _milliseconds;

        public void Advance(TimeSpan by) => _milliseconds += (long)by.TotalMilliseconds;
    }
}
