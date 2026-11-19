using Microsoft.Windows.AppLifecycle;
using TablePro.App.Model;
using Windows.ApplicationModel.Activation;

namespace TablePro.App.Services;

// A packaged launch carries a link as a protocol activation and files as a file activation; the execution alias and an
// unpackaged launch carry both on the command line.
internal static class ActivationRequests
{
    // Read on the thread that raised the activation, before it is handed to the UI thread.
    public static ActivationRequest Of(AppActivationArguments activation)
    {
        ArgumentNullException.ThrowIfNull(activation);
        return activation.Kind switch
        {
            ExtendedActivationKind.Protocol when activation.Data is IProtocolActivatedEventArgs { Uri: { } uri } =>
                new ActivationRequest([uri.OriginalString], []),
            ExtendedActivationKind.File when activation.Data is IFileActivatedEventArgs { Files: { } files } =>
                ActivationRequest.FromFiles(files.Select(item => item.Path)),
            ExtendedActivationKind.Launch when activation.Data is ILaunchActivatedEventArgs launch =>
                ActivationRequest.FromCommandLine(launch.Arguments),
            _ => ActivationRequest.None,
        };
    }

    // A first launch reads its own command line, which the activation's arguments may leave out.
    public static ActivationRequest OfLaunch(AppActivationArguments activation) =>
        Of(activation) is { IsEmpty: false } request
            ? request
            : ActivationRequest.FromArguments(Environment.GetCommandLineArgs().Skip(1));
}
