using System.Text;
using TablePro.Core.Editing.MultiCursor;

namespace TablePro.Core.Tests.MultiCursor;

/// <summary>
/// Writes carets into text and reads them back: '|' is a bare caret, '[' and ']' a selection whose active end is the
/// ']', and '{' and '}' a selection whose active end is the '{'. The text holds no other use of those characters.
/// </summary>
internal static class CaretMarkup
{
    public static (FakeMultiCursorBuffer Buffer, MultiCursorModel Model) Create(string markup, int? primary = null)
    {
        var (text, carets) = Parse(markup);
        var buffer = new FakeMultiCursorBuffer(text);
        var model = new MultiCursorModel(buffer);
        model.SetCarets(carets, primary ?? carets.Count - 1);
        return (buffer, model);
    }

    public static (string Text, List<Caret> Carets) Parse(string markup)
    {
        var sb = new StringBuilder(markup.Length);
        var carets = new List<Caret>();
        var open = -1;
        foreach (var c in markup)
        {
            switch (c)
            {
                case '|':
                    carets.Add(Caret.At(sb.Length));
                    break;
                case '[' or '{':
                    open = sb.Length;
                    break;
                case ']':
                    carets.Add(new Caret(open, sb.Length));
                    break;
                case '}':
                    carets.Add(new Caret(sb.Length, open));
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }

        return (sb.ToString(), carets);
    }

    public static string Render(FakeMultiCursorBuffer buffer, MultiCursorModel model)
    {
        var text = buffer.Text;
        var sb = new StringBuilder(text.Length + (model.Count * 2));
        var at = 0;
        foreach (var caret in model.Carets)
        {
            sb.Append(text, at, caret.Start - at);
            if (caret.IsEmpty)
            {
                sb.Append('|');
            }
            else
            {
                sb.Append(caret.IsReversed ? '{' : '[').Append(text, caret.Start, caret.Length).Append(caret.IsReversed ? '}' : ']');
            }

            at = caret.End;
        }

        return sb.Append(text, at, text.Length - at).ToString();
    }
}
