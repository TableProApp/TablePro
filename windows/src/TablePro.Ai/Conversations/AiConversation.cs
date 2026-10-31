namespace TablePro.Ai.Conversations;

/// <summary>
/// One chat with the assistant. It lives in memory with its window and is never written to disk, since it can quote
/// the user's SQL and schema.
/// </summary>
public sealed class AiConversation
{
    private readonly List<AiMessage> _messages = [];
    private readonly Lock _lock = new();

    public AiConversation(Guid? connectionId = null)
    {
        ConnectionId = connectionId;
    }

    public Guid Id { get; } = Guid.NewGuid();

    /// <summary>The connection the conversation is about, whose AI policy governs every request in it.</summary>
    public Guid? ConnectionId { get; }

    public DateTimeOffset CreatedAt { get; } = DateTimeOffset.Now;

    public string? Title { get; set; }

    /// <summary>Raised after any change, possibly off the UI thread: a reply lands when its stream ends.</summary>
    public event EventHandler? Changed;

    public IReadOnlyList<AiMessage> Messages
    {
        get
        {
            lock (_lock)
            {
                return [.. _messages];
            }
        }
    }

    public int Count
    {
        get
        {
            lock (_lock)
            {
                return _messages.Count;
            }
        }
    }

    public void Add(AiMessage message)
    {
        ArgumentNullException.ThrowIfNull(message);
        lock (_lock)
        {
            _messages.Add(message);
            Title ??= message.Role == AiRole.User ? TitleFrom(message.Content) : null;
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        lock (_lock)
        {
            _messages.Clear();
            Title = null;
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Takes back a message no reply followed, so a failed request can be sent again without a duplicate.</summary>
    internal bool Remove(AiMessage message)
    {
        bool removed;
        lock (_lock)
        {
            removed = _messages.Remove(message);
        }

        if (removed)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }

        return removed;
    }

    /// <summary>The most recent turns that fit the cap, starting at a user turn as every provider expects.</summary>
    internal IReadOnlyList<AiMessage> RecentWindow(int maxMessages)
    {
        lock (_lock)
        {
            var start = Math.Max(0, _messages.Count - Math.Max(1, maxMessages));
            while (start < _messages.Count && _messages[start].Role != AiRole.User)
            {
                start++;
            }

            return _messages.GetRange(start, _messages.Count - start);
        }
    }

    private static string TitleFrom(string content)
    {
        var line = content.AsSpan().Trim();
        var newline = line.IndexOfAny('\r', '\n');
        if (newline >= 0)
        {
            line = line[..newline];
        }

        return line.Length > 60 ? string.Concat(line[..60].TrimEnd(), "...") : line.ToString();
    }
}
