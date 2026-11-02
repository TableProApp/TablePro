using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;
using Windows.Graphics;

namespace TablePro.DataGrid.Gate;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new GateApp();
        });
    }
}

// An app with no XAML files, so the WinUI controls' types come from their own metadata provider.
public sealed partial class GateApp : Application, IXamlMetadataProvider
{
    private readonly XamlControlsXamlMetaDataProvider _provider;
    private Window? _window;
    private Report? _report;

    public GateApp()
    {
        XamlControlsXamlMetaDataProvider.Initialize();
        _provider = new XamlControlsXamlMetaDataProvider();
        UnhandledException += (_, e) =>
        {
            e.Handled = true;
            _report?.Line("unhandled", e.Exception.ToString());
            _report?.Flush();
        };
    }

    public IXamlType GetXamlType(Type type) => _provider.GetXamlType(type);

    public IXamlType GetXamlType(string fullName) => _provider.GetXamlType(fullName);

    public XmlnsDefinition[] GetXmlnsDefinitions() => _provider.GetXmlnsDefinitions();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var options = new Args(Environment.GetCommandLineArgs());
        var outDir = options.Get("out", Path.Combine(Path.GetTempPath(), "grid-gate"));
        var name = options.Get("name", "gate");
        _report = new Report(Path.Combine(outDir, name + ".json"));
        _report.Line("args", string.Join(' ', Environment.GetCommandLineArgs().Skip(1)));
        _report.Line("process_arch", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString());
        _report.Line("os", Environment.OSVersion.VersionString);
        _report.Line("process_start_to_onlaunched_ms", Clock.SinceProcessStart());
        DataGridView.WarmUpFonts();
        try
        {
            Resources.MergedDictionaries.Add(new XamlControlsResources());
        }
        catch (Exception ex)
        {
            _report.Line("error", "XamlControlsResources: " + ex);
            Exit();
            return;
        }
        _window = new Window { Title = "TablePro grid gate " + name };
        _window.AppWindow.MoveAndResize(new RectInt32(40, 40, options.GetInt("width", 1440), options.GetInt("height", 900)));
        _window.Activate();
        _ = RunAsync(options, outDir, name);
    }

    private async Task RunAsync(Args options, string outDir, string name)
    {
        try
        {
            await new Gate(new RunContext(_window!, options, _report!, outDir, name)).RunAsync();
        }
        catch (Exception ex)
        {
            _report!.Line("error", ex.ToString());
        }
        _report!.Line("done_ms_since_process_start", Clock.SinceProcessStart());
        _report.Flush();
        Exit();
    }
}
