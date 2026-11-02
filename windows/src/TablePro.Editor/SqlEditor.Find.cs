using Microsoft.UI.Xaml;
using TablePro.Editor.Model;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    public bool IsFindOpen => _findBar?.IsOpen == true;

    public void OpenFind()
    {
        if (_findBar is null)
        {
            _findBar = new FindBar();
            _findBar.QueryChanged += (_, _) => FindFrom(_model.Primary.Start, backward: false);
            _findBar.NextRequested += (_, backward) => FindNext(backward);
            _findBar.CloseRequested += (_, _) => CloseFind();
            _root.Children.Add(_findBar);
        }
        var selection = _model.Primary;
        _findBar.Open(selection.IsEmpty ? null : Document.GetText(selection.Start, selection.Length));
        Invalidate();
    }

    public void CloseFind()
    {
        _findBar?.Close();
        Focus(FocusState.Keyboard);
        Invalidate();
    }

    // F3 and Shift+F3: the next match after the selection, or before it, wrapping at the ends.
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
            var all = TextSearch.InRange(Document, query, 0, Document.Length);
            _findBar.ShowCount(all.FindIndex(m => m.Start == found.Start) + 1, all.Count);
        }
        else
        {
            _findBar.ShowCount(0, 0);
        }
        Invalidate();
    }
}
