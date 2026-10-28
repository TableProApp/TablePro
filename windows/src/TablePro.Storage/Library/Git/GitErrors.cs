namespace TablePro.Storage.Library.Git;

public enum GitProcessFailure
{
    LaunchFailed,
    TimedOut,
    OutputTooLarge,
}

/// <summary>Git could not be run to completion: it did not start, took too long, or printed too much.</summary>
public sealed class GitProcessException : Exception
{
    public GitProcessException()
        : this(GitProcessFailure.LaunchFailed, "Git could not be started.")
    {
    }

    public GitProcessException(string message)
        : this(GitProcessFailure.LaunchFailed, message)
    {
    }

    public GitProcessException(string message, Exception innerException)
        : this(GitProcessFailure.LaunchFailed, message, innerException)
    {
    }

    public GitProcessException(GitProcessFailure failure, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Failure = failure;
    }

    public GitProcessFailure Failure { get; }
}

/// <summary>Git ran and exited with a failure status; <see cref="Exception.Message"/> is what it printed.</summary>
public class GitCommandException : Exception
{
    public GitCommandException()
        : this(1, string.Empty)
    {
    }

    public GitCommandException(string message)
        : this(1, message)
    {
    }

    public GitCommandException(string message, Exception innerException)
        : base(message, innerException)
    {
        ExitCode = 1;
        Output = message;
    }

    public GitCommandException(int exitCode, string output)
        : base(output.Length == 0 ? FormattableString.Invariant($"Git exited with status {exitCode}.") : output)
    {
        ExitCode = exitCode;
        Output = output;
    }

    public int ExitCode { get; }

    /// <summary>What git printed, empty when it printed nothing.</summary>
    public string Output { get; }
}

/// <summary>A pull stopped because the branch and its upstream each have commits the other lacks.</summary>
public sealed class GitPullDivergedException : GitCommandException
{
    public GitPullDivergedException()
    {
    }

    public GitPullDivergedException(string message)
        : base(message)
    {
    }

    public GitPullDivergedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public GitPullDivergedException(int exitCode, string output)
        : base(exitCode, output)
    {
    }
}

/// <summary>Why a linked folder's Git action failed, worded for the person who asked for it.</summary>
public static class GitErrorText
{
    public static string Describe(Exception error) => error switch
    {
        GitPullDivergedException => "The branch and its upstream branch each have commits the other lacks. Finish this pull in a Git client.",
        GitCommandException => "Git stopped with the message below.",
        GitProcessException { Failure: GitProcessFailure.TimedOut } => "Git did not respond in time.",
        GitProcessException { Failure: GitProcessFailure.OutputTooLarge } => "Git printed more output than TablePro can read.",
        GitUnavailableException => "Git is not installed. Install Git for Windows to use Git in linked folders.",
        _ => error.Message,
    };

    /// <summary>What git printed, to show under <see cref="Describe"/>, or null.</summary>
    public static string? Output(Exception error) =>
        error is GitCommandException { Output.Length: > 0 } failure ? failure.Output : null;
}

/// <summary>No git executable was found.</summary>
public sealed class GitUnavailableException : Exception
{
    public GitUnavailableException()
        : base("Git is not installed.")
    {
    }

    public GitUnavailableException(string message)
        : base(message)
    {
    }

    public GitUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
