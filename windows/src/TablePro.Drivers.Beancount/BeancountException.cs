namespace TablePro.Drivers.Beancount;

/// <summary>A ledger that cannot be projected or queried, with a message meant for the user.</summary>
public sealed class BeancountException : Exception
{
    public BeancountException()
    {
    }

    public BeancountException(string message)
        : base(message)
    {
    }

    public BeancountException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    internal const string ReadOnlyMessage = "Beancount ledgers are exposed as a read-only SQL database.";

    internal static BeancountException ConnectionFailed(string message) => new("Failed to open Beancount ledger: " + message);
}
