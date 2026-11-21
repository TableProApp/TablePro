using TablePro.Editor.Model;
using TablePro.Interop;

namespace TablePro.Editor;

// Format Query reflows the selection, or the whole text without one, as the macOS editor's does.
public sealed partial class SqlEditor
{
    private bool _formatting;

    // The formatter knows only SQL's layout.
    public bool CanFormat => _lexer is CoreSqlLexer { Grammar: not (SqlGrammar.Redis or SqlGrammar.Mongo) };

    // One undo step. The caret keeps the characters around it; a formatted selection leaves the caret after it.
    public async Task FormatAsync()
    {
        if (_lexer is not CoreSqlLexer lexer || !CanFormat || _formatting)
        {
            return;
        }
        CloseCompletion();
        _model.CollapseToPrimary();
        var selection = _model.Primary;
        var whole = Document.Snapshot();
        var (start, end) = selection.IsEmpty ? (0, whole.Length) : (selection.Start, selection.End);
        if (string.IsNullOrWhiteSpace(whole[start..end]))
        {
            return;
        }
        var version = Document.Version;
        var grammar = lexer.Grammar;
        var caret = selection.Active;
        FormattedSql formatted;
        _formatting = true;
        try
        {
            formatted = await Task.Run(() => selection.IsEmpty
                    ? SqlFormatter.Format(grammar, whole, caret)
                    : new FormattedSql(SqlFormatter.FormatSelection(grammar, whole, start, end), 0))
                .ConfigureAwait(true);
        }
        catch (TableProException)
        {
            return;
        }
        finally
        {
            _formatting = false;
        }
        // Text typed while the format ran wins over the format.
        if (_disposed || Document.Version != version || formatted.Text == whole[start..end])
        {
            return;
        }
        var after = selection.IsEmpty
            ? Selection.Caret(formatted.Caret)
            : Selection.Caret(start + formatted.Text.Length);
        Edit(() => _model.ReplaceRange(start, end, formatted.Text, after));
    }
}
