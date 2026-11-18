using TablePro.Interop;

namespace TablePro.App.Model;

public enum AssistantAvailability
{
    // No provider: nothing is sent anywhere.
    Off,

    // The connection's policy is Never.
    Blocked,
    Ready,
}

// What one workspace's assistant may send: the provider Settings names and the connection's policy, both read again
// before every request, and the answer under Ask each time, which holds for the place it named until the workspace
// disconnects.
public sealed class AssistantAccess(Func<AiSettings?> settings, Func<AiPolicy> policy)
{
    private Destination? _granted;
    private bool _asking;

    public AssistantAvailability Availability =>
        settings() is null ? AssistantAvailability.Off
        : policy() == AiPolicy.Never ? AssistantAvailability.Blocked
        : AssistantAvailability.Ready;

    // A request may go without asking: the policy allows it, or the user did for where requests go now.
    public bool IsGranted =>
        Availability == AssistantAvailability.Ready
        && Current() is { } current
        && (policy() == AiPolicy.Allow || _granted == current);

    // The last check before a request goes: settings may have changed while it was made.
    public bool MaySendTo(AiSettings sent)
    {
        ArgumentNullException.ThrowIfNull(sent);
        return IsGranted && Current() == Destination.Of(sent);
    }

    // Under Ask each time the first request asks, naming where the data goes; one question at a time.
    public async Task<bool> PermitAsync(Func<AiSettings, Task<bool>> ask)
    {
        ArgumentNullException.ThrowIfNull(ask);
        if (Availability != AssistantAvailability.Ready || settings() is not { } askedFor)
        {
            return false;
        }

        if (IsGranted)
        {
            return true;
        }

        if (_asking)
        {
            return false;
        }

        _asking = true;
        bool allowed;
        try
        {
            allowed = await ask(askedFor).ConfigureAwait(true);
        }
        finally
        {
            _asking = false;
        }

        // The answer is for the place the question named; the policy or the provider may have changed meanwhile.
        if (allowed && Availability == AssistantAvailability.Ready && Current() == Destination.Of(askedFor))
        {
            _granted = Destination.Of(askedFor);
        }

        return IsGranted;
    }

    private Destination? Current() => settings() is { } now ? Destination.Of(now) : null;

    // The provider and the address its requests go to; the model is not where the data goes.
    private sealed record Destination(AiProvider Provider, string Address)
    {
        public static Destination Of(AiSettings settings) => new(
            settings.Provider,
            settings.Provider == AiProvider.OpenAICompatible
                ? (settings.Address ?? string.Empty).Trim().TrimEnd('/')
                : string.Empty);
    }
}
