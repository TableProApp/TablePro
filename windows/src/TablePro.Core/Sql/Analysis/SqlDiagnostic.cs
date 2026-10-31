namespace TablePro.Core.Sql.Analysis;

/// <summary>How the editor marks a diagnostic: a red squiggle for an error, an amber one for a warning.</summary>
public enum SqlDiagnosticSeverity
{
    Error,
    Warning,
}

/// <summary>What a diagnostic is about, so tests and callers need not match on message text.</summary>
public enum SqlDiagnosticCode
{
    /// <summary>A <c>)</c>, <c>]</c> or <c>}</c> with no opener, or closing a different kind of bracket.</summary>
    UnmatchedClosingBracket,

    /// <summary>An opener left open once the caret has left its statement.</summary>
    UnclosedBracket,

    UnterminatedComment,

    /// <summary>A string left open, reported only once the caret is before it, since typing at the caret may still close it.</summary>
    UnterminatedString,

    UnterminatedQuotedName,

    /// <summary>Full-width punctuation, a curly quote or a non-ASCII space where SQL needs its ASCII form.</summary>
    ConfusableCharacter,

    /// <summary>An unqualified table the catalog does not list and the script does not create.</summary>
    UnknownTable,

    /// <summary><c>alias.column</c> naming a column the table's loaded structure does not have.</summary>
    UnknownColumn,

    /// <summary><c>x.column</c> where no table, alias or common table expression of the statement is called x.</summary>
    UnknownQualifier,
}

/// <summary>A problem in the editor's text, as a range in UTF-16 code units of the text that was analyzed.</summary>
public readonly record struct SqlDiagnostic(int Start, int Length, SqlDiagnosticSeverity Severity, SqlDiagnosticCode Code, string Message)
{
    public int End => Start + Length;

    public SqlTextRange Range => new(Start, Length);
}

/// <summary>A range of the analyzed text in UTF-16 code units.</summary>
public readonly record struct SqlTextRange(int Start, int Length)
{
    public int End => Start + Length;

    /// <summary>Whether the offset falls on the range or just after it, where a caret that finished typing the name sits.</summary>
    public bool Touches(int offset) => offset >= Start && offset <= End;

    public bool Contains(int offset) => offset >= Start && offset < End;
}
