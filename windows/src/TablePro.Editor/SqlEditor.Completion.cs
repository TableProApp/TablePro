using Microsoft.UI.Xaml.Automation;
using TablePro.Editor.Model;
using TablePro.Editor.Model.Vim;
using TablePro.Interop;
using Windows.System;

namespace TablePro.Editor;

// The core decides what completes and how it is written; the editor shows the list and inserts the choice, as the macOS
// editor's list behaves (windows/docs/decisions/0002-sql-editor-control.md, Completion and format).
public sealed partial class SqlEditor
{
    private const int MaxShown = 100;
    private const int LongestWord = 512;

    // A script of megabytes is not copied and lexed on each key: a completion reads the lines around the caret.
    private const int ContextBefore = 128 * 1024;
    private const int ContextAfter = 32 * 1024;

    private static readonly TimeSpan CompletionDelay = TimeSpan.FromMilliseconds(50);

    private ICompletionSource? _completionSource;
    private CompletionPopup? _completionPopup;
    private SqlCompletion? _completion;
    private CancellationTokenSource? _completionRequest;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _completionTimer;
    private int _completionStart = -1;
    private (int Start, string Word)? _unmatched;
    private int _rankGeneration;
    private (double WordX, double CaretX, double CaretY)? _placedAt;
    private bool _completionHooked;

    // Null leaves the editor without completion.
    public ICompletionSource? CompletionSource
    {
        get => _completionSource;
        set
        {
            CloseCompletion();
            _completionSource = value;
            HookCompletion();
        }
    }

    public bool IsCompletionOpen => _completionPopup?.IsOpen == true;

    // Ctrl+Space: anywhere a name or a keyword can go, with or without a word typed.
    public void ShowCompletion() => RequestCompletion(asked: true);

    public void CloseCompletion()
    {
        _completionTimer?.Stop();
        CancelCompletionRequest();
        _rankGeneration++;
        _completion?.Dispose();
        _completion = null;
        _completionStart = -1;
        _placedAt = null;
        if (_completionPopup is { IsOpen: true } popup)
        {
            popup.Close();
            AutomationProperties.GetControlledPeers(this).Remove(popup.List);
        }
    }

    private void CancelCompletionRequest()
    {
        _completionRequest?.Cancel();
        _completionRequest = null;
    }

    private void HookCompletion()
    {
        if (_completionHooked)
        {
            return;
        }
        _completionHooked = true;
        _model.SelectionsChanged += (_, _) =>
        {
            _completionTimer?.Stop();
            CancelCompletionRequest();
            FollowCaret();
        };
        Document.Changed += (_, change) =>
        {
            CancelCompletionRequest();
            if (_unmatched is { } unmatched && change.Offset < unmatched.Start)
            {
                _unmatched = null;
            }
            if (_completionStart >= 0 && change.Offset < _completionStart)
            {
                CloseCompletion();
            }
        };
        Document.Reset += (_, _) =>
        {
            _unmatched = null;
            CloseCompletion();
        };
        Unloaded += (_, _) => CloseCompletion();
        LostFocus += (_, _) => CloseCompletion();
        ActualThemeChanged += (_, _) => CloseCompletion();
        FramePresented += (_, _) => PlaceCompletion();
    }

    // The keys the list takes while it shows, ahead of Vim; another chord closes it and goes on to the editor.
    private bool HandleCompletionKey(VirtualKey key, bool control, bool shift, bool alt)
    {
        if (IsModifier(key))
        {
            return false;
        }
        if (_completionPopup is not { IsOpen: true } popup)
        {
            // A list still being read never opens after Escape, which still goes on to the editor.
            if (key == VirtualKey.Escape)
            {
                CloseCompletion();
            }
            return false;
        }
        if (control || alt)
        {
            CloseCompletion();
            return false;
        }
        switch (key)
        {
            case VirtualKey.Up:
                popup.Move(-1);
                return true;
            case VirtualKey.Down:
                popup.Move(1);
                return true;
            case VirtualKey.PageUp:
                popup.Move(-popup.PageRows);
                return true;
            case VirtualKey.PageDown:
                popup.Move(popup.PageRows);
                return true;
            case VirtualKey.Enter or VirtualKey.Tab when !shift:
                AcceptCompletion();
                return true;
            case VirtualKey.Escape:
                CloseCompletion();
                // Vim's Escape also leaves Insert mode, as it does with Vim's own list.
                return _vim is null;
            default:
                return false;
        }
    }

    private static bool IsModifier(VirtualKey key) => key is VirtualKey.Shift or VirtualKey.Control or VirtualKey.Menu
        or VirtualKey.LeftShift or VirtualKey.RightShift or VirtualKey.LeftControl or VirtualKey.RightControl
        or VirtualKey.LeftMenu or VirtualKey.RightMenu or VirtualKey.LeftWindows or VirtualKey.RightWindows;

    // Typing that put text in the document; Vim's keys outside Insert mode never open a list.
    private void AfterTyped(string text)
    {
        if (_completionSource is null || text.Length == 0 || (_vim is { } vim && !vim.Mode.IsInsert()))
        {
            return;
        }
        if (text.All(TextUnits.IsWordChar))
        {
            // An open list narrows as the caret moves, and a longer word than one that matched nothing matches nothing.
            if (IsCompletionOpen || _completionRequest is not null || ExtendsUnmatched())
            {
                return;
            }
            ScheduleCompletion();
            return;
        }
        _unmatched = null;
        // A place such as FROM or `alias.` asks for a name before one is typed.
        if (text is "." or " " or "," or "(")
        {
            ScheduleCompletion();
        }
    }

    private void ScheduleCompletion()
    {
        if (_completionTimer is null)
        {
            _completionTimer = DispatcherQueue.CreateTimer();
            _completionTimer.Interval = CompletionDelay;
            _completionTimer.IsRepeating = false;
            _completionTimer.Tick += (_, _) => RequestCompletion(asked: false);
        }
        _completionTimer.Stop();
        _completionTimer.Start();
    }

    private async void RequestCompletion(bool asked)
    {
        _completionTimer?.Stop();
        if (_completionSource is not { } source || _disposed || _model.HasMultipleSelections || !_model.Primary.IsEmpty
            || IsComposing || (_vim is { } vim && !vim.Mode.IsInsert()))
        {
            return;
        }
        _completionRequest?.Cancel();
        var request = new CancellationTokenSource();
        _completionRequest = request;
        var caret = _model.Primary.Active;
        var (from, text) = CompletionContext(caret);
        SqlCompletion? completion;
        try
        {
            completion = await source.CompleteAsync(text, caret - from, asked, request.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (TableProException)
        {
            // A catalog the connection cannot read now offers nothing.
            completion = null;
        }
        catch (ObjectDisposedException)
        {
            // The tab closed under the read.
            completion = null;
        }
        finally
        {
            if (ReferenceEquals(_completionRequest, request))
            {
                _completionRequest = null;
            }
            request.Dispose();
        }
        if (request.IsCancellationRequested || IsComposing || _disposed)
        {
            completion?.Dispose();
            return;
        }
        if (completion is null)
        {
            if (asked)
            {
                CloseCompletion();
            }
            return;
        }
        // The answer still has to be for the word at the caret.
        var start = from + completion.WordStart;
        if (WordFrom(start) is not { } word || word != completion.Word)
        {
            completion.Dispose();
            return;
        }
        CloseCompletion();
        _completion = completion;
        _completionStart = start;
        Narrow(word);
    }

    private void FollowCaret()
    {
        if (_completionStart < 0)
        {
            return;
        }
        if (WordFrom(_completionStart) is { } word)
        {
            Narrow(word);
        }
        else
        {
            CloseCompletion();
        }
    }

    // The word from start to the caret, or null once the caret has left it.
    private string? WordFrom(int start)
    {
        if (_model.HasMultipleSelections || !_model.Primary.IsEmpty)
        {
            return null;
        }
        var caret = _model.Primary.Active;
        if (start < 0 || caret < start || caret - start > LongestWord)
        {
            return null;
        }
        var word = Document.GetText(start, caret - start);
        return word.All(TextUnits.IsWordChar) ? word : null;
    }

    private bool ExtendsUnmatched()
    {
        if (_unmatched is not { } unmatched || WordFrom(unmatched.Start) is not { } word)
        {
            return false;
        }
        return word.StartsWith(unmatched.Word, StringComparison.Ordinal)
            && WordStartBefore(_model.Primary.Active) == unmatched.Start;
    }

    private int WordStartBefore(int caret)
    {
        var start = caret;
        while (start > 0 && caret - start < LongestWord && TextUnits.IsWordChar(Document.CharAt(start - 1)))
        {
            start--;
        }
        return start;
    }

    // Ranking 50,000 names takes milliseconds, so it runs off the UI thread and only the last word's ranking lands.
    private async void Narrow(string word)
    {
        if (_completion is not { } completion)
        {
            return;
        }
        var generation = ++_rankGeneration;
        CompletionPage page;
        try
        {
            page = await Task.Run(() => completion.Rank(word, MaxShown)).ConfigureAwait(true);
        }
        catch (ObjectDisposedException)
        {
            return;
        }
        if (generation != _rankGeneration || !ReferenceEquals(completion, _completion) || IsComposing || _disposed)
        {
            return;
        }
        if (page.Total == 0)
        {
            _unmatched = (_completionStart, word);
            CloseCompletion();
            return;
        }
        if (_completionPopup is null)
        {
            _completionPopup = new CompletionPopup(_root);
            _completionPopup.SelectionChanged += (_, _) => AnnounceCompletion();
            _completionPopup.Accepted += (_, _) => AcceptCompletion();
        }
        var popup = _completionPopup;
        var opening = !popup.IsOpen;
        popup.Show(page, word, ActualTheme);
        if (opening)
        {
            AutomationProperties.GetControlledPeers(this).Add(popup.List);
        }
        _placedAt = null;
        PlaceCompletion();
    }

    // The choice replaces the whole word the caret is in, as one undo step.
    private async void AcceptCompletion()
    {
        if (_completionPopup is not { IsOpen: true } popup || _completion is not { } completion)
        {
            return;
        }
        var start = _completionStart;
        if (WordFrom(start) is not { } word)
        {
            CloseCompletion();
            return;
        }
        var item = popup.Selected;
        // A key typed since the rows were ranked: the closest match for the word as it is now, ranked off the UI
        // thread too, and dropped if the text or the list moved on meanwhile.
        if (word != popup.Word)
        {
            var version = Document.Version;
            try
            {
                var closest = await Task.Run(() => completion.Rank(word, 1)).ConfigureAwait(true);
                item = closest.Items.Count > 0 ? closest.Items[0] : null;
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            if (Document.Version != version || !ReferenceEquals(completion, _completion) || WordFrom(start) != word)
            {
                return;
            }
        }
        var caret = _model.Primary.Active;
        CloseCompletion();
        if (item is null)
        {
            return;
        }
        var end = caret;
        while (end < Document.Length && end - caret < LongestWord && TextUnits.IsWordChar(Document.CharAt(end)))
        {
            end++;
        }
        var text = item.InsertText;
        Edit(() => _model.ReplaceRange(start, end, text));
    }

    private (int From, string Text) CompletionContext(int caret)
    {
        var line = Document.GetLineFromOffset(Math.Max(0, caret - ContextBefore));
        // From a line outside any token, so a long comment or string is never read as SQL.
        while (line > 0 && (_highlighter is null || !_highlighter.IsLineClean(line)))
        {
            line--;
        }
        var from = Document.GetLineStart(line);
        var to = Math.Min(Document.Length, caret + ContextAfter);
        return (from, Document.GetText(from, to - from));
    }

    private void PlaceCompletion()
    {
        if (_completionPopup is not { IsOpen: true } popup || _completionStart < 0)
        {
            return;
        }
        var caret = CaretRect(_model.Primary.Active);
        if (caret.Bottom < 0 || caret.Top > ViewHeight)
        {
            CloseCompletion();
            return;
        }
        var word = CaretRect(_completionStart);
        var at = (word.X, caret.X, caret.Y);
        if (at == _placedAt)
        {
            return;
        }
        _placedAt = at;
        popup.Place(word, caret, ViewWidth, ViewHeight);
    }

    private void AnnounceCompletion()
    {
        if (_completionPopup is { IsOpen: true } popup)
        {
            _peer?.Announce(popup.Announcement);
        }
    }
}
