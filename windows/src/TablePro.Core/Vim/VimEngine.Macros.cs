namespace TablePro.Core.Vim;

public sealed partial class VimEngine
{
    /// <summary>Deep enough for a macro that calls others, shallow enough that @a inside qa cannot recurse forever.</summary>
    private const int MaxMacroDepth = 50;

    private readonly Dictionary<char, List<(char Key, bool Shift)>> _macroBuffers = [];
    private MacroTarget? _pendingMacroTarget;
    private int _pendingMacroCount = 1;
    private char? _macroRecording;
    private char? _lastInvokedMacro;
    private int _macroPlaybackDepth;

    private enum MacroTarget
    {
        Record,
        Replay,
    }

    private void HandleMacroTarget(MacroTarget kind, char register)
    {
        if (kind == MacroTarget.Record)
        {
            _macroRecording = register;
            _macroBuffers[register] = [];
            return;
        }

        var target = register == '@' ? _lastInvokedMacro : register;
        var count = Math.Max(1, _pendingMacroCount);
        _pendingMacroCount = 1;
        if (target is not { } name || !_macroBuffers.TryGetValue(name, out var keys) || keys.Count == 0)
        {
            return;
        }

        _lastInvokedMacro = name;

        // Copied, so a macro that records into its own register while replaying cannot change what is replayed.
        var snapshot = keys.ToArray();
        for (var i = 0; i < count; i++)
        {
            ReplayMacro(snapshot);
        }
    }

    private void ReplayMacro((char Key, bool Shift)[] keys)
    {
        if (_macroPlaybackDepth >= MaxMacroDepth)
        {
            return;
        }

        _macroPlaybackDepth++;
        var saved = _macroRecording;
        _macroRecording = null;
        try
        {
            foreach (var (key, shift) in keys)
            {
                Process(key, shift);
            }
        }
        finally
        {
            _macroRecording = saved;
            _macroPlaybackDepth--;
        }
    }
}
