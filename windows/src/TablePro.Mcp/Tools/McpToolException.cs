namespace TablePro.Mcp.Tools;

public enum McpToolErrorCode
{
    InvalidArgument,
    NotFound,
    NotConnected,

    /// <summary>The user's settings refuse it; asking again gets the same answer.</summary>
    Denied,

    /// <summary>The user said no in the app, or the request was cancelled.</summary>
    UserCancelled,
    Timeout,
    QueryFailed,
    Internal,
}

/// <summary>
/// Why a tool did not do what it was asked. It reaches the client as a tool result with <c>isError</c> set, text first
/// with a code a client can match on, because clients render a protocol error without its message.
/// </summary>
public sealed class McpToolException : Exception
{
    public McpToolException()
    {
    }

    public McpToolException(string message)
        : base(message)
    {
    }

    public McpToolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public McpToolException(McpToolErrorCode code, string message)
        : base(message)
    {
        Code = code;
    }

    public McpToolErrorCode Code { get; } = McpToolErrorCode.Internal;

    public string WireCode => Code switch
    {
        McpToolErrorCode.InvalidArgument => "invalid_argument",
        McpToolErrorCode.NotFound => "not_found",
        McpToolErrorCode.NotConnected => "not_connected",
        McpToolErrorCode.Denied => "denied",
        McpToolErrorCode.UserCancelled => "user_cancelled",
        McpToolErrorCode.Timeout => "timeout",
        McpToolErrorCode.QueryFailed => "query_failed",
        _ => "internal_failure",
    };

    internal static McpToolException Invalid(string message) => new(McpToolErrorCode.InvalidArgument, message);
}
