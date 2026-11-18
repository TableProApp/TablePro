using TablePro.Interop;

namespace TablePro.App.Model;

// What the user asked in one turn: a typed question, or an editor action on a statement.
public abstract record AssistantAsk
{
    private AssistantAsk()
    {
    }

    public sealed record Typed(string Text) : AssistantAsk;

    // Error is the server's, for Fix.
    public sealed record Action(AiAction Kind, string Statement, string? Error = null) : AssistantAsk;
}

// Message is what the provider receives; Answer stays null until a reply ends, and a failed one never gets one.
public sealed record AssistantTurn(AssistantAsk Asked, string Message)
{
    public string? Answer { get; set; }
}

// The turns of one conversation, sent whole with each question. The system prompt is set when it starts.
public sealed class AssistantConversation(string system, IReadOnlyList<string> described)
{
    private readonly List<AssistantTurn> _turns = [];

    // The tables whose structure the system prompt carries.
    public IReadOnlyList<string> Described { get; } = described;

    public IReadOnlyList<AssistantTurn> Turns => _turns;

    public AssistantTurn Ask(AssistantAsk asked, string message)
    {
        var turn = new AssistantTurn(asked, message);
        _turns.Add(turn);
        return turn;
    }

    // The last question's reply, or what came of it before Stop.
    public void Answer(string text)
    {
        if (_turns.Count > 0)
        {
            _turns[^1].Answer = text;
        }
    }

    // The request for the last question. A turn with no answer is left out, so questions and answers alternate.
    public AiChat Request()
    {
        var messages = new List<AiMessage>();
        for (var index = 0; index < _turns.Count; index++)
        {
            var turn = _turns[index];
            if (index == _turns.Count - 1)
            {
                messages.Add(new AiMessage(AiRole.User, turn.Message));
                break;
            }

            if (!string.IsNullOrWhiteSpace(turn.Answer))
            {
                messages.Add(new AiMessage(AiRole.User, turn.Message));
                messages.Add(new AiMessage(AiRole.Assistant, turn.Answer));
            }
        }

        return new AiChat(system, messages);
    }
}
