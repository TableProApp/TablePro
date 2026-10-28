using System.Text;
using TablePro.Core.Editing.MultiCursor;

namespace TablePro.Core.Tests.MultiCursor;

/// <summary>An in-memory <see cref="IMultiCursorBuffer"/> that keeps an undo snapshot per <see cref="Apply"/> call, as the editor does.</summary>
internal sealed class FakeMultiCursorBuffer(string text = "") : IMultiCursorBuffer
{
    public string Text { get; set; } = text;

    public string LineBreak { get; set; } = "\n";

    /// <summary>The text before each Apply call: one undo step each.</summary>
    public List<string> UndoSteps { get; } = [];

    public List<MultiCursorEditKind> Kinds { get; } = [];

    public void Apply(IReadOnlyList<TextEdit> edits, MultiCursorEditKind kind)
    {
        UndoSteps.Add(Text);
        Kinds.Add(kind);
        var sb = new StringBuilder(Text.Length);
        var at = 0;
        foreach (var edit in edits)
        {
            Assert.True(edit.Start >= at, "Edits must be sorted and must not overlap.");
            sb.Append(Text, at, edit.Start - at).Append(edit.Text);
            at = edit.End;
        }

        sb.Append(Text, at, Text.Length - at);
        Text = sb.ToString();
    }

    public void Undo()
    {
        Text = UndoSteps[^1];
        UndoSteps.RemoveAt(UndoSteps.Count - 1);
    }
}
