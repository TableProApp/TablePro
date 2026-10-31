using System.Text;

namespace TablePro.Ai.Prompts;

/// <summary>The editor's AI actions, as the macOS app's <c>AIQueryAction</c> names them.</summary>
public enum AiQueryAction
{
    Explain,
    Optimize,
    Review,

    /// <summary>Correct a statement the server refused, with its error.</summary>
    FixError,
}

/// <summary>Every prompt the assistant sends, in one place, ported from the macOS app's <c>AIPromptTemplates</c>.</summary>
public static class AiPromptTemplates
{
    public const int MaxEditorChars = 8_000;
    public const int MaxStatementChars = 20_000;
    public const int MaxErrorChars = 2_000;
    public const int MaxRequestChars = 4_000;
    public const int InlineBeforeChars = 2_000;
    public const int InlineAfterChars = 500;
    public const string CursorMarker = "[CURSOR]";

    /// <summary>The system prompt of a conversation, fixed when it starts.</summary>
    public static string ChatSystemPrompt(SchemaContext context, string? editorText = null, string? connectionRules = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        var engine = EngineName(context);
        var sb = new StringBuilder("You are the database assistant in TablePro, a database client for Windows. ");
        AppendWhereabouts(sb, context);
        sb.Append("\nAnswer questions about this database and its SQL. Write SQL for ").Append(engine)
            .Append(" in code blocks marked sql, using the tables and columns listed here and ").Append(engine)
            .Append("'s identifier quoting. Keep answers short. You cannot run anything: the user reads what you write and runs it themselves.");

        var schema = SchemaContextBuilder.Render(context);
        if (schema.Length > 0)
        {
            sb.Append("\n\n## Database Schema\n").Append(schema);
        }

        if (!string.IsNullOrWhiteSpace(editorText))
        {
            var (text, cut) = Head(editorText.Trim(), MaxEditorChars);
            sb.Append("\n\n## Current Query\n").Append(MarkdownFence.Wrap(text, "sql"));
            if (cut)
            {
                sb.Append("\n(The editor's text is cut here.)");
            }
        }

        AppendRules(sb, connectionRules);
        return sb.ToString();
    }

    /// <summary>The user's message for Explain, Optimize, Review or Fix with AI on a statement.</summary>
    public static string QueryActionPrompt(AiQueryAction action, string statement, string? errorMessage = null, bool withStructure = true, string typeName = "SQL query", string language = "sql")
    {
        ArgumentNullException.ThrowIfNull(statement);
        var (text, _) = Head(statement.Trim(), MaxStatementChars);
        var sb = new StringBuilder(Instruction(action, typeName, withStructure)).Append("\n\n").Append(MarkdownFence.Wrap(text, language));
        if (action == AiQueryAction.FixError && !string.IsNullOrWhiteSpace(errorMessage))
        {
            var (error, _) = Head(errorMessage.Trim(), MaxErrorChars);
            sb.Append("\n\nError:\n").Append(MarkdownFence.Wrap(error, "text"));
        }

        return sb.ToString();
    }

    public static string Instruction(AiQueryAction action, string typeName = "SQL query", bool withStructure = true) => action switch
    {
        AiQueryAction.Review => $"Review this {typeName} for correctness, performance and safety. "
            + (withStructure ? "The table structure attached, with its indexes and row counts, decides what is fast. " : string.Empty)
            + "List each finding with its severity and the exact fix. If it is fine as written, say so.",
        AiQueryAction.Explain => withStructure
            ? $"Explain what this {typeName} does, step by step, using the table structure attached."
            : $"Explain what this {typeName} does, step by step.",
        AiQueryAction.Optimize => withStructure
            ? $"Optimize this {typeName}. Use the indexes and row counts attached to decide what is slow, and give the rewrite or the index to add, with the reason for each."
            : $"Optimize this {typeName}, and give the rewrite or the index to add, with the reason for each.",
        AiQueryAction.FixError => withStructure
            ? $"This {typeName} failed with the error below. Find the cause using the table structure attached and fix it."
            : $"This {typeName} failed with the error below. Find the cause and fix it.",
        _ => throw new ArgumentOutOfRangeException(nameof(action), action, null),
    };

    /// <summary>The user's message asking for SQL from a description in plain words.</summary>
    public static string GenerateSqlPrompt(string request, SchemaContext context)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(context);
        var (text, _) = Head(request.Trim(), MaxRequestChars);
        return $"Write one {EngineName(context)} SQL statement that does what the request below asks, using only the tables and columns in the schema. "
            + "Reply with the statement in a single code block marked sql, then at most two sentences on any assumption you made. "
            + "If the schema has nothing the request needs, say so instead of guessing names.\n\nRequest:\n"
            + MarkdownFence.Wrap(text, "text");
    }

    /// <summary>The system prompt of an inline suggestion (suggest while typing).</summary>
    public static string InlineSuggestSystemPrompt(SchemaContext? context = null)
    {
        var sb = new StringBuilder(
            "You are an SQL autocomplete engine. Given the SQL text around the cursor, return ONLY the completion text that should appear at the cursor. "
            + "Rules: "
            + "- Return raw SQL only, no markdown, no backticks, no explanation. "
            + "- Do NOT repeat any text that already exists before or after the cursor. "
            + "- Keep completions concise (1-2 lines preferred). "
            + "- If no meaningful completion exists, return an empty string. "
            + "- Match the SQL dialect and style of the existing query. "
            + "- The completion must continue EXACTLY from the cursor position: if the cursor is mid-word (e.g., \"SE[CURSOR]\"), "
            + "complete the word without adding spaces (e.g., \"LECT * FROM ...\"). "
            + "- Only include a leading space when the cursor is after a complete token followed by no space.");

        if (context is not null)
        {
            if (!string.IsNullOrWhiteSpace(context.EngineName))
            {
                sb.Append("\n\nThe database is ").Append(context.EngineName).Append('.');
            }

            var schema = SchemaContextBuilder.Render(context);
            if (schema.Length > 0)
            {
                sb.Append("\n\n## Database Schema\n").Append(schema);
            }
        }

        return sb.ToString();
    }

    /// <summary>The user's message of an inline suggestion: the end of the text before the cursor and the start of the text after.</summary>
    public static string InlineSuggestMessage(string textBefore, string? textAfter = null)
    {
        ArgumentNullException.ThrowIfNull(textBefore);
        var before = textBefore.Length > InlineBeforeChars ? textBefore[^InlineBeforeChars..] : textBefore;
        var after = string.IsNullOrWhiteSpace(textAfter) ? string.Empty : Head(textAfter, InlineAfterChars).Text;
        return $"Complete the SQL at {CursorMarker}:\n\n{before}{CursorMarker}{after}";
    }

    private static string EngineName(SchemaContext context) =>
        string.IsNullOrWhiteSpace(context.EngineName) ? "SQL" : context.EngineName.Trim();

    private static void AppendWhereabouts(StringBuilder sb, SchemaContext context)
    {
        sb.Append("The user is connected to a ").Append(EngineName(context)).Append(" database");
        if (!string.IsNullOrWhiteSpace(context.Database))
        {
            sb.Append(" named ").Append(SchemaContextBuilder.Quote(context.Database));
        }

        if (!string.IsNullOrWhiteSpace(context.DefaultSchema))
        {
            sb.Append(", in schema ").Append(SchemaContextBuilder.Quote(context.DefaultSchema));
        }

        sb.Append('.');
    }

    private static void AppendRules(StringBuilder sb, string? rules)
    {
        if (!string.IsNullOrWhiteSpace(rules))
        {
            sb.Append("\n\n## Connection-Specific Rules\n").Append(rules.Trim());
        }
    }

    private static (string Text, bool Cut) Head(string text, int maxChars)
    {
        if (text.Length <= maxChars)
        {
            return (text, false);
        }

        // Cutting between a surrogate pair would send half a character.
        var cut = char.IsHighSurrogate(text[maxChars - 1]) ? maxChars - 1 : maxChars;
        return (text[..cut], true);
    }
}
