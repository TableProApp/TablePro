using TablePro.Core.Connections;

namespace TablePro.Ai.Assistant;

/// <summary>What the Ask Each Time prompt shows: the connection, and the provider with the address its requests go to.</summary>
public sealed record AiApprovalRequest(ConnectionProfile Profile, string ProviderName, Uri ProviderAddress);

/// <summary>The UI's prompt for Ask Each Time. True lets the connection's structure and SQL go to the provider.</summary>
public delegate ValueTask<bool> AiApprovalCallback(AiApprovalRequest request, CancellationToken cancellationToken);

public enum AiAccessDenial
{
    /// <summary>The connection's AI Assistant setting is Never.</summary>
    PolicyNever,

    /// <summary>The user said no to Ask Each Time.</summary>
    Declined,

    /// <summary>The setting is Ask Each Time and the app gave the service no way to ask.</summary>
    NoApprover,
}

/// <summary>A request the connection's AI policy refuses. Nothing was sent.</summary>
public sealed class AiAccessDeniedException : Exception
{
    public AiAccessDeniedException()
    {
    }

    public AiAccessDeniedException(string message)
        : base(message)
    {
    }

    public AiAccessDeniedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public AiAccessDeniedException(Guid connectionId, AiAccessDenial reason, string message)
        : base(message)
    {
        ConnectionId = connectionId;
        Reason = reason;
    }

    public Guid ConnectionId { get; }

    public AiAccessDenial Reason { get; }
}
