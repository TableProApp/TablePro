using System.Text;

namespace TablePro.Core.Vim;

/// <summary>
/// A Vim emulation over an <see cref="IVimBuffer"/>: normal, visual, insert, replace and command-line modes with
/// counts, operators, motions, text objects, registers, marks, macros, search and dot repeat. It holds no UI; the
/// editor hands it one key at a time through <see cref="Process"/> and reads <see cref="Mode"/> and
/// <see cref="Status"/> back.
/// </summary>
/// <remarks>
/// Ported from the macOS app's engine (TablePro/Core/Vim), whose tests pin the behaviour. Keys arrive as characters:
/// Escape is '\u001B', Enter '\r', Backspace '\b' and Control chords their control characters.
/// </remarks>
public sealed partial class VimEngine
{
    internal const char Escape = '\u001B';
    private const int MaxCount = 99_999;

    private readonly IVimBuffer _buffer;
    private readonly StringBuilder _pendingKeys = new();
    private readonly Dictionary<char, int> _marks = [];
    private readonly Dictionary<char, VimRegister> _namedRegisters = [];
    private readonly VimRegister[] _numberedRegisters = [.. Enumerable.Repeat(VimRegister.Empty, 10)];

    private VimMode _mode = VimMode.Normal;
    private VimRegister _register = VimRegister.Empty;
    private VimOperator? _pendingOperator;
    private int _countPrefix;
    private int _operatorCount;
    private int? _goalColumn;
    private bool _insertGroupOpen;
    private string _status = VimMode.Normal.DisplayLabel;

    public VimEngine(IVimBuffer buffer)
    {
        ArgumentNullException.ThrowIfNull(buffer);
        _buffer = buffer;
    }

    /// <summary>Raised when the mode changes, with the new mode.</summary>
    public event EventHandler<VimMode>? ModeChanged;

    /// <summary>Raised when <see cref="Status"/> changes.</summary>
    public event EventHandler? StatusChanged;

    /// <summary>
    /// Raised with an Ex command entered after ':' (without the colon), and with the tab commands gt and gT produce.
    /// <see cref="VimCommandLineHandler"/> interprets them.
    /// </summary>
    public event EventHandler<string>? CommandEntered;

    /// <summary>Raised when a yank or delete fills the unnamed register, so the editor can mirror it to the clipboard.</summary>
    public event EventHandler<VimRegister>? RegisterWritten;

    public VimMode Mode => _mode;

    /// <summary>The visual-mode cursor end, or the caret in the other modes, where a block caret belongs.</summary>
    public int CursorOffset { get; private set; }

    /// <summary>The unnamed register, which p and P paste.</summary>
    public VimRegister Register => _register;

    /// <summary>Registers 0 (last yank) to 9 (older deletes).</summary>
    public IReadOnlyList<VimRegister> NumberedRegisters => _numberedRegisters;

    public IReadOnlyDictionary<char, VimRegister> NamedRegisters => _namedRegisters;

    public VimOperator? PendingOperator => _pendingOperator;

    /// <summary>The keys of a command still being typed, such as "2d" or "\"a", shown beside the mode.</summary>
    public string PendingKeys => _pendingKeys.ToString();

    /// <summary>The register a macro is being recorded into, if any.</summary>
    public char? RecordingMacro => _macroRecording;

    /// <summary>The mode, the pending keys and macro recording as one line for a status bar.</summary>
    public string Status => _status;

    /// <summary>Handles one key. Returns false when the key is not the engine's and the editor should handle it.</summary>
    public bool Process(char key, bool shift = false)
    {
        var recordingTarget = _macroRecording;
        var wasInsert = _mode.IsInsert;
        _buffer.BeginUndoGroup();
        bool consumed;
        try
        {
            if (!_mode.IsInsert && !_mode.IsCommandLine)
            {
                AppendPendingKey(key);
            }

            consumed = _mode.Kind switch
            {
                VimModeKind.Normal => ProcessNormal(key, shift),
                VimModeKind.Insert => ProcessInsert(key),
                VimModeKind.Replace => ProcessReplace(key),
                VimModeKind.Visual => ProcessVisual(key, shift),
                _ => ProcessCommandLine(key, _mode.CommandBuffer ?? string.Empty),
            };
        }
        finally
        {
            CloseUndoGroup(wasInsert);
        }

        if (recordingTarget is { } target && _macroRecording == target)
        {
            _macroBuffers[target].Add((key, shift));
        }

        if (!_mode.IsVisual)
        {
            CursorOffset = _buffer.SelectionStart;
        }

        if (!HasPendingInput || _mode.IsInsert || _mode.IsCommandLine)
        {
            _pendingKeys.Clear();
        }

        UpdateStatus();
        return consumed;
    }

    /// <summary>Drops any half-typed command and returns to normal mode, closing an open insert undo step.</summary>
    public void Reset()
    {
        _pendingOperator = null;
        _countPrefix = 0;
        _operatorCount = 0;
        _pendingG = false;
        _capturingDot = null;
        ClearPendingInput();
        SetMode(VimMode.Normal);
        if (_insertGroupOpen)
        {
            _insertGroupOpen = false;
            _buffer.EndUndoGroup();
        }

        _pendingKeys.Clear();
        UpdateStatus();
    }

    internal void SetMode(VimMode mode)
    {
        if (_mode == mode)
        {
            return;
        }

        var wasInsert = _mode.IsInsert;
        _mode = mode;
        if (!wasInsert && mode.Kind == VimModeKind.Insert)
        {
            OnInsertModeEntered();
        }

        ModeChanged?.Invoke(this, mode);
    }

    internal int ConsumeCount()
    {
        var motionCount = _countPrefix > 0 ? _countPrefix : 1;
        var opCount = _operatorCount > 0 ? _operatorCount : 1;
        _countPrefix = 0;
        _operatorCount = 0;
        return motionCount * opCount;
    }

    private string Text => _buffer.Text;

    private int Length => _buffer.Text.Length;

    private int Caret => _buffer.SelectionStart;

    private VimRange Selection => new(_buffer.SelectionStart, _buffer.SelectionLength);

    private bool HasPendingInput =>
        _countPrefix > 0 || _pendingOperator is not null || _pendingG || _pendingFindChar is not null || _pendingReplaceChar
        || _pendingMarkSet || _pendingMarkJumpExact is not null || _pendingRegisterSelect || _pendingReplaceCharForVisual
        || _pendingZ || _pendingTextObject || _pendingMacroTarget is not null || _pendingBracketOpen is not null
        || _selectedRegister is not null;

    private char CharAt(int offset)
    {
        var text = Text;
        return offset >= 0 && offset < text.Length ? text[offset] : '\0';
    }

    private VimRange LineAt(int offset) => VimText.LineRange(Text, offset);

    private int ContentEnd(VimRange line) => VimText.ContentEnd(Text, line);

    private int LineCount => VimText.LineCount(Text);

    private (int Line, int Column) LineAndColumn(int offset) => VimText.LineAndColumn(Text, offset);

    private int OffsetForLine(int line, int column) => VimText.OffsetForLine(Text, line, column);

    private string Substring(VimRange range)
    {
        var text = Text;
        var start = Math.Max(0, range.Start);
        var length = Math.Min(range.Length, text.Length - start);
        return length > 0 ? text.Substring(start, length) : string.Empty;
    }

    private void MoveTo(int offset) => _buffer.Select(offset, 0);

    private void Select(VimRange range) => _buffer.Select(range.Start, range.Length);

    private void ReplaceRange(VimRange range, string text) => _buffer.Replace(range.Start, range.Length, text);

    private void CloseUndoGroup(bool wasInsert)
    {
        // A key that enters insert or replace mode keeps its undo group open, so the text typed until Escape undoes
        // together with the change that started it, as one Vim change.
        if (!wasInsert && _mode.IsInsert && !_insertGroupOpen)
        {
            _insertGroupOpen = true;
            return;
        }

        _buffer.EndUndoGroup();
        if (wasInsert && !_mode.IsInsert && _insertGroupOpen)
        {
            _insertGroupOpen = false;
            _buffer.EndUndoGroup();
        }
    }

    private void AppendPendingKey(char key)
    {
        if (key == Escape)
        {
            return;
        }

        if (char.IsControl(key))
        {
            _pendingKeys.Append('^').Append((char)(key ^ 0x40));
        }
        else
        {
            _pendingKeys.Append(key);
        }
    }

    private void ClearPendingInput()
    {
        _pendingFindChar = null;
        _pendingReplaceChar = false;
        _pendingMarkSet = false;
        _pendingMarkJumpExact = null;
        _pendingRegisterSelect = false;
        _pendingReplaceCharForVisual = false;
        _pendingZ = false;
        _pendingTextObject = false;
        _pendingMacroTarget = null;
        _pendingBracketOpen = null;
        _selectedRegister = null;
    }

    private void UpdateStatus()
    {
        string status;
        if (_mode.IsCommandLine)
        {
            status = _mode.DisplayLabel;
        }
        else
        {
            var sb = new StringBuilder(_mode.DisplayLabel);
            if (_pendingKeys.Length > 0)
            {
                sb.Append("  ").Append(_pendingKeys);
            }

            if (_macroRecording is { } register)
            {
                sb.Append("  recording @").Append(register);
            }

            status = sb.ToString();
        }

        if (!string.Equals(status, _status, StringComparison.Ordinal))
        {
            _status = status;
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
