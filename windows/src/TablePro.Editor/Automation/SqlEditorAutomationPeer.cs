using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Automation.Text;
using Windows.Foundation;

namespace TablePro.Editor.Automation;

// Text and Text2 patterns, so Narrator reads by character, word and line and follows the caret.
internal sealed partial class SqlEditorAutomationPeer(SqlEditor editor) : FrameworkElementAutomationPeer(editor), ITextProvider2
{
    internal SqlEditor Editor { get; } = editor;

    public ITextRangeProvider DocumentRange => new EditorTextRange(this, 0, Editor.Document.Length);

    public SupportedTextSelection SupportedTextSelection => SupportedTextSelection.Multiple;

    public ITextRangeProvider[] GetSelection() =>
        Editor.Model.Selections.Select(s => (ITextRangeProvider)new EditorTextRange(this, s.Start, s.End)).ToArray();

    public ITextRangeProvider[] GetVisibleRanges()
    {
        var (first, last) = Editor.VisibleLines();
        return [new EditorTextRange(this, Editor.Document.GetLineStart(first), Editor.Document.GetLineEnd(last))];
    }

    public ITextRangeProvider RangeFromChild(IRawElementProviderSimple childElement) => DocumentRange;

    public ITextRangeProvider RangeFromPoint(Point screenLocation)
    {
        var offset = Editor.OffsetAt(Editor.FromUiaClient(screenLocation));
        return new EditorTextRange(this, offset, offset);
    }

    public ITextRangeProvider RangeFromAnnotation(IRawElementProviderSimple annotationElement) => DocumentRange;

    public ITextRangeProvider GetCaretRange(out bool isActive)
    {
        isActive = Editor.FocusState != Microsoft.UI.Xaml.FocusState.Unfocused;
        var caret = Editor.Model.Primary.Active;
        return new EditorTextRange(this, caret, caret);
    }

    internal IRawElementProviderSimple Provider => ProviderFromPeer(this);

    internal void RaiseTextChanged()
    {
        if (ListenerExists(AutomationEvents.TextPatternOnTextChanged))
        {
            RaiseAutomationEvent(AutomationEvents.TextPatternOnTextChanged);
        }
    }

    internal void RaiseSelectionChanged()
    {
        if (ListenerExists(AutomationEvents.TextPatternOnTextSelectionChanged))
        {
            RaiseAutomationEvent(AutomationEvents.TextPatternOnTextSelectionChanged);
        }
    }

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface is PatternInterface.Text or PatternInterface.Text2 ? this : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Edit;

    protected override string GetClassNameCore() => nameof(SqlEditor);

    protected override string GetNameCore()
    {
        var name = base.GetNameCore();
        return string.IsNullOrEmpty(name) ? "SQL editor" : name;
    }
}
