namespace TablePro.App.Model;

public enum HandOverResult
{
    Taken,
    OwnerExited,
    NoAnswer,
}

// A launch must always end with a window somewhere: in the app it handed over to, or its own.
public static class LaunchClaim
{
    public const int Attempts = 3;

    // findOwner gives null once this process holds the data folder's key, or the process that holds it.
    public static bool StartsHere<TOwner>(
        Func<TOwner?> findOwner, Func<TOwner, HandOverResult> handOver, Action<Exception> failed)
        where TOwner : class
    {
        ArgumentNullException.ThrowIfNull(findOwner);
        ArgumentNullException.ThrowIfNull(handOver);
        ArgumentNullException.ThrowIfNull(failed);
        try
        {
            for (var attempt = 0; attempt < Attempts; attempt++)
            {
                if (findOwner() is not { } owner)
                {
                    return true;
                }

                switch (handOver(owner))
                {
                    case HandOverResult.Taken:
                        return false;
                    case HandOverResult.NoAnswer:
                        return true;
                    case HandOverResult.OwnerExited:
                        break;
                }
            }
        }
        catch (Exception exception)
        {
            failed(exception);
        }

        return true;
    }

    // The lookup gives null when the owner gave the key up between registering and finding, as one that quits does.
    public static TOwner? OwnerOf<TOwner>(TOwner? found, Func<TOwner, bool> isCurrent)
        where TOwner : class
    {
        ArgumentNullException.ThrowIfNull(isCurrent);
        return found is null || isCurrent(found) ? null : found;
    }

    // The wait ends on the redirect, the owner's exit or the timeout; only a redirect that finished means it was taken.
    public static HandOverResult ReadWait(bool timedOut, Task redirect)
    {
        ArgumentNullException.ThrowIfNull(redirect);
        if (timedOut)
        {
            return HandOverResult.NoAnswer;
        }

        return redirect.IsCompletedSuccessfully ? HandOverResult.Taken : HandOverResult.OwnerExited;
    }
}
