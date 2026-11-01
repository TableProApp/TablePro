using TablePro.Drivers.Beancount.Localization;

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

    internal static string ReadOnlyMessage => BeancountStrings.Get("Beancount/ReadOnly");

    internal static BeancountException ConnectionFailed(string message) => new(BeancountStrings.Format("Beancount/OpenFailed", message));
}
