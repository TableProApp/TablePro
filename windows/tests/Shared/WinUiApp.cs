using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.XamlTypeInfo;
using Windows.Graphics;

namespace TablePro.Testing;

// One WinUI app per test run, on an STA thread of its own, in the gate's 1440 x 900 window.
internal static class WinUiApp
{
    private static readonly Lazy<Task<DispatcherQueue>> s_queue = new(StartAsync);

    public static Window Window { get; private set; } = null!;

    // An exception XAML raised on the UI thread during the test, which would otherwise end the process.
    public static Exception? Unhandled { get; set; }

    public static async Task RunAsync(Func<Task> body)
    {
        var queue = await s_queue.Value.WaitAsync(TimeSpan.FromSeconds(90));
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        queue.TryEnqueue(async () =>
        {
            try
            {
                Unhandled = null;
                await body();
                if (Unhandled is { } error)
                {
                    throw new InvalidOperationException("XAML raised an unhandled exception", error);
                }
                done.SetResult();
            }
            catch (Exception ex)
            {
                done.SetException(ex);
            }
        });
        await done.Task.WaitAsync(TimeSpan.FromMinutes(5));
    }

    public static Task NextFrameAsync()
    {
        var tcs = new TaskCompletionSource();
        EventHandler<object>? handler = null;
        handler = (_, _) =>
        {
            CompositionTarget.Rendering -= handler;
            tcs.TrySetResult();
        };
        CompositionTarget.Rendering += handler;
        return tcs.Task;
    }

    private static Task<DispatcherQueue> StartAsync()
    {
        var ready = new TaskCompletionSource<DispatcherQueue>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                WinRT.ComWrappersSupport.InitializeComWrappers();
                Application.Start(callback =>
                {
                    var queue = DispatcherQueue.GetForCurrentThread();
                    SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(queue));
                    _ = new TestApp(window =>
                    {
                        Window = window;
                        ready.TrySetResult(queue);
                    }, error => ready.TrySetException(error));
                });
            }
            catch (Exception ex)
            {
                ready.TrySetException(ex);
            }
        })
        {
            IsBackground = true,
            Name = "WinUI",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return ready.Task;
    }
}

// An app with no XAML files, so the WinUI controls' types come from their own metadata provider.
internal sealed partial class TestApp : Application, IXamlMetadataProvider
{
    private readonly XamlControlsXamlMetaDataProvider _provider;
    private readonly Action<Window> _ready;
    private readonly Action<Exception> _failed;

    public TestApp(Action<Window> ready, Action<Exception> failed)
    {
        _ready = ready;
        _failed = failed;
        XamlControlsXamlMetaDataProvider.Initialize();
        _provider = new XamlControlsXamlMetaDataProvider();
        UnhandledException += (_, e) =>
        {
            e.Handled = true;
            WinUiApp.Unhandled ??= e.Exception;
        };
    }

    public IXamlType GetXamlType(Type type) => _provider.GetXamlType(type);

    public IXamlType GetXamlType(string fullName) => _provider.GetXamlType(fullName);

    public XmlnsDefinition[] GetXmlnsDefinitions() => _provider.GetXmlnsDefinitions();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Resources.MergedDictionaries.Add(new XamlControlsResources());
            var window = new Window { Title = typeof(TestApp).Assembly.GetName().Name ?? nameof(TestApp) };
            window.AppWindow.MoveAndResize(new RectInt32(40, 40, 1440, 900));
            window.Activate();
            _ready(window);
        }
        catch (Exception ex)
        {
            _failed(ex);
        }
    }
}
