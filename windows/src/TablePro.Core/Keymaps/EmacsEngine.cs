using TablePro.Core.Editing.MultiCursor;

namespace TablePro.Core.Keymaps;

/// <summary>
/// Runs Emacs commands at every caret of a <see cref="MultiCursorModel"/>. The region is the selection and the mark is
/// its anchor, so an active mark grows with the model's extending moves and every caret keeps a mark of its own.
/// </summary>
public sealed class EmacsEngine
{
    private readonly MultiCursorModel _model;
    private readonly KillRing _ring;
    private bool _markActive;
    private int _versionAfterLastCommand = -1;

    public EmacsEngine(MultiCursorModel model, KillRing? ring = null)
    {
        ArgumentNullException.ThrowIfNull(model);
        _model = model;
        _ring = ring ?? KillRing.Shared;
    }

    /// <summary>
    /// Whether motions extend the region. A click, a Shift+arrow or an edit outside this engine ends it, as in Emacs,
    /// even one that leaves the carets where they were, which is why the model's change count decides.
    /// </summary>
    public bool IsMarkActive
    {
        get
        {
            if (_markActive && _model.Version != _versionAfterLastCommand)
            {
                _markActive = false;
            }

            return _markActive;
        }
    }

    public void Perform(EmacsCommand command)
    {
        var extending = IsMarkActive;
        try
        {
            switch (command.Kind)
            {
                case EmacsCommandKind.Move:
                    _model.Move(ToCaretMotion(command.Motion), extending);
                    break;
                case EmacsCommandKind.KillLine:
                    EndRegion();
                    Kill(forward: true, _model.KillToLineEnd);
                    break;
                case EmacsCommandKind.KillWord:
                    EndRegion();
                    Kill(forward: true, () => _model.DeleteTo(CaretMotion.WordEnd));
                    break;
                case EmacsCommandKind.BackwardKillWord:
                    EndRegion();
                    Kill(forward: false, () => _model.DeleteTo(CaretMotion.WordLeft));
                    break;
                case EmacsCommandKind.KillRegion:
                    _markActive = false;
                    if (HasText(_model.SelectedTexts()))
                    {
                        Kill(forward: true, _model.DeleteSelections);
                    }

                    break;
                case EmacsCommandKind.CopyRegion:
                    var copied = _model.SelectedTexts();
                    if (HasText(copied))
                    {
                        _ring.Kill(copied, forward: true, before: null, after: State);
                    }

                    _model.CollapseToActive();
                    _markActive = false;
                    break;
                case EmacsCommandKind.Yank:
                    EndRegion();
                    Yank(_ring.Yank(), replacing: null);
                    break;
                case EmacsCommandKind.YankPop:
                    if (_ring.YankedRanges(State) is { } previous)
                    {
                        Yank(_ring.Rotate(), previous);
                    }

                    break;
                case EmacsCommandKind.SetMark:
                    _model.CollapseToActive();
                    _markActive = true;
                    break;
                case EmacsCommandKind.Quit:
                    _model.CollapseToActive();
                    _markActive = false;
                    break;
            }
        }
        finally
        {
            _versionAfterLastCommand = _model.Version;
        }
    }

    public static CaretMotion ToCaretMotion(EmacsMotion motion) => motion switch
    {
        EmacsMotion.ForwardChar => CaretMotion.Right,
        EmacsMotion.BackwardChar => CaretMotion.Left,
        EmacsMotion.NextLine => CaretMotion.Down,
        EmacsMotion.PreviousLine => CaretMotion.Up,
        EmacsMotion.BeginningOfLine => CaretMotion.LineStart,
        EmacsMotion.EndOfLine => CaretMotion.LineEnd,
        EmacsMotion.ForwardWord => CaretMotion.WordEnd,
        EmacsMotion.BackwardWord => CaretMotion.WordLeft,
        _ => CaretMotion.Right,
    };

    private KillContinuation State => new(_model, _model.Version, _model.TextLength);

    private static bool HasText(IReadOnlyList<string> strings)
    {
        foreach (var s in strings)
        {
            if (s.Length > 0)
            {
                return true;
            }
        }

        return false;
    }

    private void Kill(bool forward, Func<IReadOnlyList<string>> delete)
    {
        var before = State;
        var removed = delete();
        if (HasText(removed))
        {
            _ring.Kill(removed, forward, before, State);
        }
    }

    private void Yank(IReadOnlyList<string> pieces, IReadOnlyList<(int Start, int End)>? replacing)
    {
        if (pieces.Count == 0)
        {
            return;
        }

        var inserted = _model.Insert(pieces, replacing);
        var ranges = new (int Start, int End)[inserted.Count];
        for (var i = 0; i < inserted.Count; i++)
        {
            ranges[i] = (inserted[i].Start, inserted[i].Start + inserted[i].Length);
        }

        _ring.DidYank(State, ranges);
    }

    // Commands that act at point leave an active region first, so they act at point and not on the region.
    private void EndRegion()
    {
        if (!_markActive)
        {
            return;
        }

        _model.CollapseToActive();
        _markActive = false;
    }
}
