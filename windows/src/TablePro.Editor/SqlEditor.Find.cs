using Microsoft.UI.Xaml;
using TablePro.Editor.Model;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    private const int CountLimit = 10_000;

    public bool IsFindOpen => _findBar?.IsOpen == true;

    internal bool IsReplaceOpen => _findBar is { IsOpen: true, IsReplaceShown: true };

    public void OpenFind() => ShowFindBar(replace: false);

    public void OpenReplace() => ShowFindBar(replace: true);

    public void CloseFind()
    {
        _findBar?.Close();
        Focus(FocusState.Keyboard);
        Invalidate();
    }

    public void FindNext(bool backward)
    {
        if (_findBar is null || string.IsNullOrEmpty(_findBar.Query.Text))
        {
            OpenFind();
            return;
        }
        var selection = _model.Primary;
        FindFrom(backward ? selection.Start : selection.End, backward);
    }

    // Replaces the selection only when it is exactly a match, as the find widgets of VS Code and Visual Studio do.
    internal void ReplaceNext()
    {
        if (_findBar is null || string.IsNullOrEmpty(_findBar.Query.Text))
        {
            return;
        }
        var selection = _model.Primary;
        var replacement = TextSearch.ReplacementAt(Document, _findBar.Query, selection.Start, selection.Length,
            _findBar.ReplaceText);
        if (replacement is null)
        {
            FindFrom(selection.Start, backward: false);
            return;
        }
        Edit(() => _model.ReplaceRange(selection.Start, selection.End, replacement));
        FindFrom(_model.Primary.End, backward: false);
    }

    internal void ReplaceAll()
    {
        if (_findBar is null)
        {
            return;
        }
        var replacements = TextSearch.Replacements(Document, _findBar.Query, _findBar.ReplaceText);
        if (replacements.Count > 0)
        {
            Edit(() => _model.ReplaceRanges(replacements));
        }
        _findBar.ShowReplaced(replacements.Count);
        Invalidate();
    }

    private void ShowFindBar(bool replace)
    {
        if (_findBar is null)
        {
            _findBar = new FindBar();
            _findBar.QueryChanged += (_, _) => FindFrom(_model.Primary.Start, backward: false);
            _findBar.NextRequested += (_, backward) => FindNext(backward);
            _findBar.ReplaceRequested += (_, _) => ReplaceNext();
            _findBar.ReplaceAllRequested += (_, _) => ReplaceAll();
            _findBar.CloseRequested += (_, _) => CloseFind();
            _root.Children.Add(_findBar);
        }
        var selection = _model.Primary;
        _findBar.Open(selection.IsEmpty ? null : Document.GetText(selection.Start, selection.Length), replace);
        Invalidate();
    }

    private void FindFrom(int from, bool backward)
    {
        if (_findBar is null)
        {
            return;
        }
        var query = _findBar.Query;
        var match = TextSearch.Next(Document, query, from, backward);
        if (match is { } found)
        {
            _model.SetSelection(found.Start, found.Start + found.Length);
            EnsureCaretVisible();
            // Counting stops at a limit, so a one-letter search in a 5 MB script stays quick.
            var all = TextSearch.InRange(Document, query, 0, Document.Length, CountLimit);
            _findBar.ShowCount(all.FindIndex(m => m.Start == found.Start) + 1, all.Count, all.Count >= CountLimit);
        }
        else
        {
            _findBar.ShowCount(0, 0, false);
        }
        Invalidate();
    }
}
