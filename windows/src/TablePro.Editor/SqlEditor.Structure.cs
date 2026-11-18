using Microsoft.UI.Dispatching;
using TablePro.Editor.Model;

namespace TablePro.Editor;

// Statements and fold regions come from the lexer once per version of the text: at once for a short text, off the UI
// thread after typing pauses for a long one, mapped through each edit in between.
public sealed partial class SqlEditor
{
    // Below this, a fresh read costs less than a frame, so it runs before the frame that needs it.
    private const int AnalyzeInlineBelow = 64 * 1024;

    private static readonly TimeSpan s_analyzePause = TimeSpan.FromMilliseconds(200);

    private readonly List<SyntaxSpan> _bracketTokens = [];
    private DocumentStructure _structure = DocumentStructure.Empty;
    private DispatcherQueueTimer? _analyzeTimer;
    private long _analyzing = -1;
    private bool _foldingEnabled = true;
    private bool _highlightStatement;
    private (long Version, int Caret, (int Open, int Close)? Pair) _bracket = (-1, -1, null);
    private HashSet<int>? _foldsToRestore;

    // Chevrons in the gutter, Ctrl+Shift+[ and ], and the menu's Fold items; off opens every fold.
    public bool IsFoldingEnabled
    {
        get => _foldingEnabled;
        set
        {
            if (_foldingEnabled == value)
            {
                return;
            }
            _foldingEnabled = value;
            if (!value)
            {
                _model.Rows.Folds.Clear();
            }
            StructureChanged();
            UpdateWrap();
            UpdateScrollBars();
            Invalidate();
        }
    }

    // A band behind the statement the caret is in, the one Run Statement sends; the host turns it on.
    public bool HighlightsCurrentStatement
    {
        get => _highlightStatement;
        set
        {
            if (_highlightStatement == value)
            {
                return;
            }
            _highlightStatement = value;
            StructureChanged();
            Invalidate();
        }
    }

    // Lines folded now, by the line each fold starts on.
    public IReadOnlyList<FoldRegion> Folds => _model.Rows.Folds.Folded;

    // What a session keeps: the folds a restore has not applied yet, else the first line of each fold.
    public IReadOnlyList<int> FoldedLines =>
        _foldsToRestore is { } pending ? [.. pending.Order()] : [.. Folds.Select(fold => fold.StartLine)];

    // A fold opened or closed, by a command, a click or an edit; the text and its version stay as they were.
    public event EventHandler? FoldsChanged;

    // A session's folds, applied to the regions the text has once it is read; a region gone since stays open.
    public void RestoreFolds(IEnumerable<int> startLines)
    {
        ArgumentNullException.ThrowIfNull(startLines);
        _foldsToRestore = [.. startLines];
        Invalidate();
    }

    // Puts the caret at offset, opening a fold that hides it, and scrolls it into view.
    public void GoTo(int offset)
    {
        _model.SetCaret(offset);
        EnsureCaretVisible();
        Invalidate();
    }

    // The innermost region around the caret's line that is not folded yet, as VS Code's Fold picks it.
    public bool FoldAtCaret()
    {
        var line = Document.GetLineFromOffset(_model.Primary.Active);
        FoldRegion? target = null;
        foreach (var region in RegionsNow())
        {
            if (region.StartLine > line)
            {
                break;
            }
            if (line <= region.EndLine && !_model.Rows.Folds.IsFolded(region.StartLine)
                && (target is not { } inner || region.StartLine >= inner.StartLine))
            {
                target = region;
            }
        }
        return target is { } found && Fold([found]);
    }

    public bool UnfoldAtCaret() => _model.Rows.Folds.Unfold(Document.GetLineFromOffset(_model.Primary.Active));

    // Top-level regions only, as the macOS editor's Fold All folds statements and leaves what is inside them.
    public bool FoldAll() => RegionsNow().Count > 0 && Fold([.. _structure.TopLevel()]);

    public bool UnfoldAll() => _model.Rows.Folds.Clear();

    // For the gutter's chevron: the region starting on the line folds or opens.
    public bool ToggleFold(int line)
    {
        if (_model.Rows.Folds.Unfold(line))
        {
            return true;
        }
        return FoldSet.FindStart(RegionsNow(), line) is { } region && Fold([region]);
    }

    internal IReadOnlyList<FoldRegion> RegionsNow()
    {
        EnsureStructure();
        return _foldingEnabled ? _structure.Regions : [];
    }

    // Carets inside what folds move to the end of its first line first, or the fold would open again at once.
    private bool Fold(IReadOnlyList<FoldRegion> regions)
    {
        if (!_foldingEnabled || regions.Count == 0)
        {
            return false;
        }
        var moved = false;
        var selections = _model.Selections.Select(selection =>
        {
            var line = Document.GetLineFromOffset(selection.Active);
            foreach (var region in regions)
            {
                if (region.Hides(line))
                {
                    moved = true;
                    return Selection.Caret(Document.GetLineEnd(region.StartLine));
                }
            }
            return selection;
        }).ToList();
        if (moved)
        {
            _model.SetSelections(selections, _model.PrimaryIndex);
        }
        var folded = _model.Rows.Folds.FoldAll(regions);
        EnsureCaretVisible();
        return folded;
    }

    // Rows move under a fold while the text's version stays, so the last frame's layouts no longer match their rows.
    private void OnFoldsChanged()
    {
        _frameLayouts.Clear();
        _frameVersion = -1;
        UpdateScrollBars();
        Invalidate();
        FoldsChanged?.Invoke(this, EventArgs.Empty);
    }

    private bool WantsStructure => _lexer is ISqlStructure && (_foldingEnabled || _highlightStatement);

    // The lexer, the text or a setting changed: what was read no longer holds.
    private void StructureChanged()
    {
        _structure = DocumentStructure.Empty;
        _bracket = (-1, -1, null);
        ScheduleAnalysis();
    }

    private void StructureEdited(TextChange change)
    {
        if (_structure.Statements.Count > 0 || _structure.Regions.Count > 0)
        {
            _structure = _structure.Map(change);
        }
        ScheduleAnalysis();
    }

    // A short text is read before the next frame; a long one once typing pauses.
    private void ScheduleAnalysis()
    {
        if (!WantsStructure || Document.Length <= AnalyzeInlineBelow || Document.Length > DocumentStructure.SizeLimit)
        {
            _analyzeTimer?.Stop();
            return;
        }
        if (_analyzeTimer is null)
        {
            _analyzeTimer = DispatcherQueue.CreateTimer();
            _analyzeTimer.IsRepeating = false;
            _analyzeTimer.Tick += (_, _) => AnalyzeInBackground();
        }
        _analyzeTimer.Interval = s_analyzePause;
        _analyzeTimer.Stop();
        _analyzeTimer.Start();
    }

    private void EnsureStructure()
    {
        if (!WantsStructure || _structure.Version == Document.Version || Document.Length > AnalyzeInlineBelow)
        {
            return;
        }
        Apply(DocumentStructure.Analyze(Document.Snapshot(), Document.Version, _lexer, _lexer as ISqlStructure));
    }

    private void AnalyzeInBackground()
    {
        if (_disposed || !WantsStructure || _structure.Version == Document.Version || _analyzing == Document.Version)
        {
            return;
        }
        var text = Document.Snapshot();
        var version = Document.Version;
        var lexer = _lexer;
        var structure = _lexer as ISqlStructure;
        var queue = DispatcherQueue;
        _analyzing = version;
        _ = Task.Run(() =>
        {
            var read = DocumentStructure.Analyze(text, version, lexer, structure);
            queue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                if (_analyzing == version)
                {
                    _analyzing = -1;
                }
                if (!_disposed && version == Document.Version && ReferenceEquals(lexer, _lexer) && WantsStructure)
                {
                    Apply(read);
                    Invalidate();
                }
            });
        });
    }

    private void Apply(DocumentStructure read)
    {
        _structure = read;
        _model.Rows.Folds.Reconcile(read.Regions);
        if (_foldsToRestore is { } restore && _foldingEnabled)
        {
            _foldsToRestore = null;
            Fold([.. read.Regions.Where(region => restore.Contains(region.StartLine))]);
        }
    }

    private void StopStructure()
    {
        _analyzeTimer?.Stop();
        _analyzing = -1;
    }

    // The statement band's range: the statement the primary caret is in, while it selects nothing.
    internal (int Start, int End)? StatementBand()
    {
        if (!_highlightStatement || !_model.Primary.IsEmpty)
        {
            return null;
        }
        EnsureStructure();
        return _structure.StatementAt(_model.Primary.Active) is { } statement && statement.End > statement.Start
            ? statement
            : null;
    }

    // Read once per caret and version, through the tokens of a window around the caret.
    internal (int Open, int Close)? BracketPair()
    {
        var caret = _model.Primary.Active;
        if (!_model.Primary.IsEmpty)
        {
            return null;
        }
        if (_bracket.Version == Document.Version && _bracket.Caret == caret)
        {
            return _bracket.Pair;
        }
        (int Open, int Close)? pair = null;
        if (IsBracketAt(caret - 1) || IsBracketAt(caret))
        {
            const int window = 32_768;
            _bracketTokens.Clear();
            var roles = (_lexer as ISqlStructure)?.Roles;
            if (_highlighter is not null && roles is not null)
            {
                var first = Document.GetLineFromOffset(Math.Max(0, caret - window));
                var last = Document.GetLineFromOffset(Math.Min(Document.Length, caret + window));
                _highlighter.GetTokens(first, last, _bracketTokens);
            }
            pair = BracketMatch.Find(Document, caret, _bracketTokens, _bracketTokens.Count == 0 ? null : roles, window);
        }
        _bracket = (Document.Version, caret, pair);
        return pair;
    }

    private bool IsBracketAt(int offset) =>
        offset >= 0 && offset < Document.Length && Document.CharAt(offset) is '(' or ')' or '[' or ']' or '{' or '}';
}
