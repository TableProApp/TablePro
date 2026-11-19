using System.Globalization;
using System.Text;

namespace TablePro.Editor.Model.Vim;

// A port of the macOS app's Vim engine (apple/TablePro/Core/Vim), which defines what each key does. A key is one
// text element; control keys come as their control characters, Escape as U+001B.
public sealed partial class VimEngine : IDisposable
{
    internal const string Escape = "\u001B";

    private const int MaxCount = 999_999;

    private readonly VimTextBuffer _buffer;
    private readonly StringBuilder _pendingKeys = new();
    private VimMode _mode;
    private string _commandLine = string.Empty;
    private int _depth;
    private UndoMark? _insertMark;
    private (VimMode, string, string, string?) _shownStatus;

    public VimEngine(EditorModel model, IVimHost host, VimRegisters? registers = null)
    {
        ArgumentNullException.ThrowIfNull(model);
        ArgumentNullException.ThrowIfNull(host);
        _buffer = new VimTextBuffer(model, host);
        Registers = registers ?? new VimRegisters();
        model.Document.Reset += OnDocumentReset;
        model.Document.Changed += OnDocumentChanged;
        model.SelectionsChanged += OnSelectionsChanged;
        _shownStatus = StatusKey();
    }

    // Lets go of the document, which outlives an engine turned off.
    public void Dispose()
    {
        _buffer.Model.Document.Reset -= OnDocumentReset;
        _buffer.Model.Document.Changed -= OnDocumentChanged;
        _buffer.Model.SelectionsChanged -= OnSelectionsChanged;
    }

    // A caret moved by an arrow or a click starts a new undo step within the insert, as Vim splits it there.
    public void BreakInsertUndo()
    {
        if (_insertMark is { } started)
        {
            _buffer.CoalesceUndo(started);
            _buffer.Model.Document.Undo.BreakJoin();
            _insertMark = _buffer.UndoMark();
        }
    }

    // Mode, command line, pending keys or macro recording changed.
    public event EventHandler? StatusChanged;

    public VimMode Mode => _mode;

    // The ex or search line being typed, with its ':', '/' or '?'; empty outside command-line mode.
    public string CommandLine => _commandLine;

    // The keys of a command still being typed, as Vim's showcmd shows them.
    public string PendingKeys => _pendingKeys.ToString();

    // A count, operator, register or other prefix waits for the rest of its command.
    public bool IsPending => HasPendingCommand;

    // The register a macro is being recorded into, or null.
    public string? RecordingRegister => MacroRecording;

    // What Vim's mode line shows, or the command line while one is typed.
    public string ModeLabel => _mode switch
    {
        VimMode.Normal => "NORMAL",
        VimMode.Insert => "INSERT",
        VimMode.Replace => "REPLACE",
        VimMode.Visual => "VISUAL",
        VimMode.VisualLine => "VISUAL LINE",
        _ => _commandLine,
    };

    // Where the block caret goes: the Visual cursor, which may be the selection's start, or the caret.
    // Outside Visual mode commands act at the selection's start, so the block is drawn there too.
    public int CursorPosition => _mode.IsVisual() ? Math.Clamp(CursorOffset, 0, _buffer.Length) : _buffer.SelectedRange.Location;

    // The character under the block caret, as offsets; empty at the end of a line or of the text.
    public (int Start, int End) CursorCharacter
    {
        get
        {
            var position = CursorPosition;
            var range = _buffer.CharacterRange(position);
            return range.Length > 0 && _buffer.CharAt(position) != '\n' ? (range.Location, range.End) : (position, position);
        }
    }

    internal VimRegisters Registers { get; }

    internal VimTextBuffer Buffer => _buffer;

    internal int CursorOffset { get; set; }

    internal VimRegister Register
    {
        get => Registers.Unnamed;
        set => Registers.Unnamed = value;
    }

    internal VimRegister[] NumberedRegisters => Registers.Numbered;

    internal Dictionary<string, VimRegister> NamedRegisters => Registers.Named;

    internal VimOperator? PendingOperator { get; set; }

    internal int CountPrefix { get; set; }

    internal int OperatorCount { get; set; }

    internal int? GoalColumn { get; set; }

    internal int? GoalRowColumn { get; set; }

    internal bool PendingG { get; set; }

    internal VimFindCharRequest? PendingFindChar { get; set; }

    internal bool PendingReplaceChar { get; set; }

    internal bool PendingMarkSet { get; set; }

    internal bool? PendingMarkJumpExact { get; set; }

    internal bool PendingRegisterSelect { get; set; }

    internal bool PendingReplaceCharForVisual { get; set; }

    internal bool PendingZ { get; set; }

    internal bool PendingTextObject { get; set; }

    internal bool PendingTextObjectAround { get; set; }

    internal VimMacroPendingKind? PendingMacroTarget { get; set; }

    internal int PendingMacroCount { get; set; } = 1;

    internal VimBracketPending? PendingBracket { get; set; }

    internal string? SelectedRegister { get; set; }

    internal VimLastFindChar? LastFindChar { get; set; }

    internal VimDotKind? LastDotKind { get; set; }

    internal Dictionary<string, int> Marks { get; private set; } = new(StringComparer.Ordinal);

    internal int EditsOnCurrentLine { get; set; }

    internal int? LastEditedLine { get; set; }

    internal int? LastJumpOrigin { get; set; }

    internal int? LastVisualStart { get; set; }

    internal int? LastVisualEnd { get; set; }

    internal bool LastVisualLinewise { get; set; }

    internal string? LastSearchPattern { get; set; }

    internal bool LastSearchForward { get; set; } = true;

    internal string? MacroRecording { get; set; }

    internal int MacroPlaybackDepth { get; set; }

    internal int VisualAnchor { get; set; }

    internal int? LastInsertOffset { get; set; }

    internal List<VimReplaceModeEdit> ReplaceModeEdits { get; } = [];

    internal int SearchCount { get; set; } = 1;

    // The column each named mark was set at, kept past the end of a line that shrinks, as Vim keeps it.
    internal Dictionary<string, int> MarkColumns { get; private set; } = new(StringComparer.Ordinal);

    // Recent edits with the positions from before each, so undoing one puts them back.
    internal List<VimEditRecord> EditJournal { get; } = [];

    public bool Process(char key, bool shift = false) => Process(key.ToString(), shift);

    // True when the engine took the key; false leaves it to the editor, as typing in Insert mode is.
    public bool Process(string key, bool shift = false)
    {
        ArgumentNullException.ThrowIfNull(key);
        var top = _depth == 0;
        var wasInsert = _mode.IsInsert();
        var mark = _buffer.UndoMark();
        var recordingTarget = MacroRecording;
        bool consumed;
        _depth++;
        _buffer.BeginCommand();
        try
        {
            consumed = _mode switch
            {
                VimMode.Normal => ProcessNormal(key, shift),
                VimMode.Insert => ProcessInsert(key),
                VimMode.Replace => ProcessReplace(key),
                VimMode.Visual or VimMode.VisualLine => ProcessVisual(key, shift),
                _ => ProcessCommandLine(key, _commandLine),
            };
        }
        finally
        {
            _buffer.EndCommand();
            _depth--;
        }
        if (recordingTarget is not null && MacroRecording == recordingTarget)
        {
            if (!Registers.Macros.TryGetValue(recordingTarget, out var keys))
            {
                keys = [];
                Registers.Macros[recordingTarget] = keys;
            }
            keys.Add(new VimKeystroke(key, shift));
        }
        if (!_mode.IsVisual())
        {
            CursorOffset = _buffer.SelectedRange.Location;
        }
        if (top)
        {
            // gj and gk keep their column on screen only while they follow each other.
            if (!_keepRowGoal && !PendingG)
            {
                GoalRowColumn = null;
            }
            _keepRowGoal = false;
            // One insert, from the key that started it to Escape, is one undo step, as Vim has it.
            if (!wasInsert && _mode.IsInsert())
            {
                _insertMark = mark;
            }
            else if (wasInsert && !_mode.IsInsert() && _insertMark is { } started)
            {
                _buffer.CoalesceUndo(started);
                _insertMark = null;
            }
            TrackPendingKeys(key);
            RaiseStatusIfChanged();
        }
        return consumed;
    }

    // Leaves whatever was pending and goes back to Normal mode.
    public void Reset()
    {
        CancelPending();
        SetMode(VimMode.Normal);
        _pendingKeys.Clear();
        RaiseStatusIfChanged();
    }

    internal void SetMode(VimMode mode, string commandLine = "")
    {
        _mode = mode;
        _commandLine = mode == VimMode.CommandLine ? commandLine : string.Empty;
        if (_depth == 0)
        {
            RaiseStatusIfChanged();
        }
    }

    // A count typed before the operator and one after it multiply, up to the most one count can hold.
    internal int ConsumeCount()
    {
        long motionCount = CountPrefix > 0 ? CountPrefix : 1;
        long opCount = OperatorCount > 0 ? OperatorCount : 1;
        CountPrefix = 0;
        OperatorCount = 0;
        return (int)Math.Min(motionCount * opCount, MaxCount);
    }

    // Escape, leaving the command line or a motion that finds nothing ends the whole command, so no part of it
    // reaches the next key.
    internal void CancelPending()
    {
        PendingOperator = null;
        CountPrefix = 0;
        OperatorCount = 0;
        PendingG = false;
        PendingFindChar = null;
        PendingReplaceChar = false;
        PendingMarkSet = false;
        PendingMarkJumpExact = null;
        PendingRegisterSelect = false;
        SelectedRegister = null;
        PendingReplaceCharForVisual = false;
        PendingZ = false;
        PendingTextObject = false;
        PendingMacroTarget = null;
        PendingMacroCount = 1;
        PendingBracket = null;
        SearchCount = 1;
    }

    // A paste, a click or a menu command moves the selection Visual mode was built on, so the mode ends with it.
    private void OnSelectionsChanged(object? sender, EventArgs e)
    {
        if (_depth == 0 && _mode.IsVisual())
        {
            Reset();
        }
    }

    // Offsets into the old text mean nothing in the new one; registers, macros and the last search carry over.
    private void OnDocumentReset(object? sender, EventArgs e)
    {
        Marks = new Dictionary<string, int>(StringComparer.Ordinal);
        MarkColumns = new Dictionary<string, int>(StringComparer.Ordinal);
        EditJournal.Clear();
        LastVisualStart = null;
        LastVisualEnd = null;
        LastVisualLinewise = false;
        LastJumpOrigin = null;
        LastInsertOffset = null;
        ReplaceModeEdits.Clear();
        EditsOnCurrentLine = 0;
        LastEditedLine = null;
        _insertMark = null;
    }

    private bool HasPendingCommand => WaitsForKey || CountPrefix > 0 || OperatorCount > 0 || SelectedRegister is not null;

    // A key still waits for the rest of its command, not counting a count or a register already typed.
    private bool WaitsForKey => PendingOperator is not null || PendingG || PendingFindChar is not null || PendingReplaceChar
        || PendingMarkSet || PendingMarkJumpExact is not null || PendingRegisterSelect || PendingReplaceCharForVisual
        || PendingZ || PendingTextObject || PendingMacroTarget is not null || PendingBracket is not null;

    private bool TakesCharacterArgument => PendingFindChar is not null || PendingReplaceChar || PendingMarkSet
        || PendingMarkJumpExact is not null || PendingZ || PendingTextObject || PendingMacroTarget is not null
        || PendingBracket is not null;

    private void TrackPendingKeys(string key)
    {
        if ((_mode == VimMode.Normal || _mode.IsVisual()) && HasPendingCommand)
        {
            _pendingKeys.Append(ShownKey(key));
        }
        else
        {
            _pendingKeys.Clear();
        }
    }

    // A control key shows as ^ and its letter, as Vim's showcmd writes it.
    private static string ShownKey(string key) =>
        key.Length == 1 && key[0] < 0x20 ? "^" + (char)(key[0] + 0x40) : key;

    private (VimMode, string, string, string?) StatusKey() => (_mode, _commandLine, PendingKeys, MacroRecording);

    private void RaiseStatusIfChanged()
    {
        var status = StatusKey();
        if (status == _shownStatus)
        {
            return;
        }
        _shownStatus = status;
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }

    internal static bool IsDigit(string key, out int digit)
    {
        if (key.Length == 1 && key[0] is >= '0' and <= '9')
        {
            digit = key[0] - '0';
            return true;
        }
        digit = 0;
        return false;
    }

    internal static string Format(int value) => value.ToString(CultureInfo.InvariantCulture);
}
