namespace TablePro.Ai.Prompts;

/// <summary>Turns an inline suggestion's raw reply into the text the editor shows after the cursor.</summary>
public static class InlineCompletion
{
    public const int MaxLines = 12;
    public const int MaxChars = 1_000;

    /// <summary>
    /// The reply without a code fence, without the current line when the model wrote it again, cut at a line end, and
    /// with no trailing space. Null when nothing is left to insert.
    /// </summary>
    public static string? Clean(string reply, string textBeforeCursor)
    {
        ArgumentNullException.ThrowIfNull(reply);
        ArgumentNullException.ThrowIfNull(textBeforeCursor);
        var unfenced = StripFence(reply).Replace(AiPromptTemplates.CursorMarker, string.Empty, StringComparison.Ordinal);
        var lastBreak = textBeforeCursor.LastIndexOf('\n');
        var line = textBeforeCursor[(lastBreak + 1)..].TrimStart();
        var continued = line.Length > 0 && unfenced.StartsWith(line, StringComparison.Ordinal) ? unfenced[line.Length..] : unfenced;

        var kept = new System.Text.StringBuilder();
        var lines = continued.Split('\n');
        for (var i = 0; i < lines.Length && i < MaxLines; i++)
        {
            if (kept.Length + lines[i].Length > MaxChars)
            {
                break;
            }

            if (i > 0)
            {
                kept.Append('\n');
            }

            kept.Append(lines[i]);
        }

        var result = kept.ToString().TrimEnd();
        return string.IsNullOrWhiteSpace(result) ? null : result;
    }

    private static string StripFence(string reply)
    {
        // A leading line break belongs to a suggestion that starts a new line, so only a fence is unwrapped.
        var trimmed = reply.TrimStart();
        if (!trimmed.StartsWith("```", StringComparison.Ordinal))
        {
            return reply;
        }

        var newline = trimmed.IndexOf('\n');
        if (newline < 0)
        {
            return string.Empty;
        }

        var body = trimmed[(newline + 1)..].TrimEnd();
        if (body.EndsWith("```", StringComparison.Ordinal))
        {
            body = body[..^3];
        }

        return body.TrimEnd('\r', '\n');
    }
}
