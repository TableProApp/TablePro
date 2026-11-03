using System.Text;

namespace TablePro.Editor.Model.Tests;

// Writes and reads documents with '|' at each caret, so a test reads as the text it checks.
internal static class Carets
{
    public static EditorModel Model(string marked, EditorOptions? options = null)
    {
        var carets = new List<int>();
        var text = new StringBuilder();
        foreach (var c in marked)
        {
            if (c == '|')
            {
                carets.Add(text.Length);
            }
            else
            {
                text.Append(c);
            }
        }
        var model = new EditorModel(new TextDocument(text.ToString()), options);
        model.SetSelections(carets.Count == 0 ? [Selection.Caret(0)] : carets.Select(Selection.Caret).ToList());
        return model;
    }

    public static string Show(EditorModel model)
    {
        var text = model.Document.GetText();
        var builder = new StringBuilder(text);
        foreach (var selection in model.Selections.OrderByDescending(s => s.Start))
        {
            if (selection.IsEmpty)
            {
                builder.Insert(selection.Active, '|');
            }
            else
            {
                builder.Insert(selection.End, ']');
                builder.Insert(selection.Start, '[');
            }
        }
        return builder.ToString();
    }
}
