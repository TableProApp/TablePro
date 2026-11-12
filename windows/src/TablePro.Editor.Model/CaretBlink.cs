namespace TablePro.Editor.Model;

// As a Windows edit control: it blinks until the caret timeout passes with no input, and an inactive window has none.
public sealed class CaretBlink
{
    private readonly TimeProvider _clock;
    private long _lastInput;
    private bool _on = true;
    private bool _focused;
    private bool _active = true;

    public CaretBlink()
        : this(TimeProvider.System)
    {
    }

    public CaretBlink(TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        _clock = clock;
        _lastInput = clock.GetTimestamp();
    }

    // What Windows uses when SPI_GETCARETTIMEOUT has no answer.
    public static TimeSpan DefaultTimeout { get; } = TimeSpan.FromSeconds(5);

    // Zero when the user turned blinking off.
    public TimeSpan Interval { get; set; }

    // Negative never stops.
    public TimeSpan Timeout { get; set; } = DefaultTimeout;

    // Whether the timer should run.
    public bool IsBlinking { get; private set; }

    public bool CaretVisible => _focused && _active && _on;

    // These return true when CaretVisible changed, so the caller draws only then.
    public bool SetFocused(bool focused)
    {
        var was = CaretVisible;
        _focused = focused;
        Restart();
        return was != CaretVisible;
    }

    public bool SetActive(bool active)
    {
        var was = CaretVisible;
        _active = active;
        Restart();
        return was != CaretVisible;
    }

    // A key, a click, a selection change or a composition update.
    public bool Restart()
    {
        var was = CaretVisible;
        _on = true;
        _lastInput = _clock.GetTimestamp();
        IsBlinking = _focused && _active && Interval > TimeSpan.Zero;
        return was != CaretVisible;
    }

    public bool Tick()
    {
        if (!IsBlinking)
        {
            return false;
        }
        if (Timeout >= TimeSpan.Zero && _clock.GetElapsedTime(_lastInput) >= Timeout)
        {
            IsBlinking = false;
            var was = _on;
            _on = true;
            return !was;
        }
        _on = !_on;
        return true;
    }
}
