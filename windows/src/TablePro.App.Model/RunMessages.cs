using System.Text;
using TablePro.Interop;

namespace TablePro.App.Model;

public enum ResultsView
{
    Results,
    Messages,
}

// One line per notice, "{severity}: {message}", as the Linux app shows the same core's notices.
public sealed class RunMessages(string cutShort)
{
    private readonly StringBuilder _text = new();

    public bool IsEmpty => _text.Length == 0;

    public string Text => _text.ToString();

    public void Reset() => _text.Clear();

    public void Add(QueryEvent queryEvent)
    {
        switch (queryEvent)
        {
            case QueryEvent.Notice notice:
                NewLine().Append(notice.Severity).Append(": ").Append(notice.Message);
                break;
            case QueryEvent.NoticeLimitReached:
                NewLine().Append(cutShort);
                break;
            default:
                break;
        }
    }

    // A view the user picked while the run went stays; a run that printed and returned no rows opens on what it printed.
    public ResultsView ViewAtEnd(bool hasRows, ResultsView? picked) =>
        IsEmpty ? ResultsView.Results : picked ?? (hasRows ? ResultsView.Results : ResultsView.Messages);

    private StringBuilder NewLine() => _text.Length == 0 ? _text : _text.Append('\n');
}
