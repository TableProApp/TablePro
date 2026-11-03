using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TablePro.DataGrid.Gate;

// The measuring plumbing of the spike's gate (lane wingates2, app/Common.cs), so the numbers compare.

internal sealed class Args
{
    private readonly Dictionary<string, string> _values = [];

    public Args(string[] argv)
    {
        for (var i = 1; i < argv.Length; i++)
        {
            if (!argv[i].StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }
            var key = argv[i][2..];
            var value = i + 1 < argv.Length && !argv[i + 1].StartsWith("--", StringComparison.Ordinal) ? argv[++i] : "true";
            _values[key] = value;
        }
    }

    public string Get(string key, string fallback) => _values.TryGetValue(key, out var v) ? v : fallback;

    public int GetInt(string key, int fallback) =>
        _values.TryGetValue(key, out var v) && int.TryParse(v, CultureInfo.InvariantCulture, out var n) ? n : fallback;

    public bool Has(string key) => _values.ContainsKey(key);
}

internal sealed record RunContext(Window Window, Args Args, Report Report, string OutDir, string Name)
{
    public string Shot(string name) => Path.Combine(OutDir, "shots", Name + "-" + name + ".png");
}

internal static class Clock
{
    private static readonly DateTime Start = Process.GetCurrentProcess().StartTime;

    public static double SinceProcessStart() => (DateTime.Now - Start).TotalMilliseconds;

    public static long Now() => Stopwatch.GetTimestamp();

    public static double Ms(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;

    public static double MsSince(long from) => Ms(from, Stopwatch.GetTimestamp());
}

internal sealed class Report
{
    private readonly string _path;
    private readonly JsonObject _root = [];

    public Report(string path)
    {
        _path = path;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    }

    public void Line(string key, object? value)
    {
        JsonNode? node = value switch
        {
            null => null,
            JsonNode n => n,
            double d => JsonValue.Create(Math.Round(d, 3)),
            float f => JsonValue.Create(Math.Round(f, 3)),
            int i => JsonValue.Create(i),
            long l => JsonValue.Create(l),
            bool b => JsonValue.Create(b),
            _ => JsonValue.Create(Convert.ToString(value, CultureInfo.InvariantCulture)),
        };
        lock (_root)
        {
            _root[key] = node;
        }
        Flush();
    }

    public void Stats(string key, IEnumerable<double> values) => Line(key, global::TablePro.DataGrid.Gate.Stats.Describe(values));

    public void Flush()
    {
        lock (_root)
        {
            File.WriteAllText(_path, _root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
    }
}

internal static class Stats
{
    public static JsonObject Describe(IEnumerable<double> source)
    {
        var v = source.ToArray();
        var o = new JsonObject { ["n"] = v.Length };
        if (v.Length == 0)
        {
            return o;
        }
        Array.Sort(v);
        double P(double q) => v[Math.Min(v.Length - 1, (int)Math.Floor((q * (v.Length - 1)) + 0.5))];
        o["mean"] = Math.Round(v.Average(), 2);
        o["p50"] = Math.Round(P(0.5), 2);
        o["p95"] = Math.Round(P(0.95), 2);
        o["p99"] = Math.Round(P(0.99), 2);
        o["max"] = Math.Round(v[^1], 2);
        o["over16_7"] = v.Count(x => x > 16.7);
        o["over50"] = v.Count(x => x > 50);
        return o;
    }
}

internal readonly record struct FrameSample(double DeltaMs, double StepMs);

internal static class Frames
{
    public static Task<long> NextAsync()
    {
        var tcs = new TaskCompletionSource<long>();
        EventHandler<object>? handler = null;
        handler = (_, _) =>
        {
            CompositionTarget.Rendering -= handler;
            tcs.TrySetResult(Clock.Now());
        };
        CompositionTarget.Rendering += handler;
        return tcs.Task;
    }

    public static async Task SkipAsync(int count)
    {
        for (var i = 0; i < count; i++)
        {
            await NextAsync();
        }
    }

    // A step's untimed work, such as checking cells, is taken out of the next delta.
    public static Task<List<FrameSample>> LoopAsync(int frames, Func<int, double> step)
    {
        var tcs = new TaskCompletionSource<List<FrameSample>>();
        var samples = new List<FrameSample>(frames);
        long last = 0;
        double untimed = 0;
        var i = 0;
        EventHandler<object>? handler = null;
        handler = (_, _) =>
        {
            var now = Clock.Now();
            var delta = last == 0 ? 0 : Clock.Ms(last, now) - untimed;
            last = now;
            if (i >= frames)
            {
                CompositionTarget.Rendering -= handler;
                samples.Add(new FrameSample(delta, 0));
                tcs.TrySetResult(samples);
                return;
            }
            double stepMs;
            try
            {
                stepMs = step(i);
            }
            catch (Exception ex)
            {
                CompositionTarget.Rendering -= handler;
                tcs.TrySetException(ex);
                return;
            }
            samples.Add(new FrameSample(delta, stepMs));
            i++;
            untimed = Math.Max(0, Clock.MsSince(now) - stepMs);
        };
        CompositionTarget.Rendering += handler;
        return tcs.Task;
    }

    public static void Report(Report report, string phase, List<FrameSample> samples)
    {
        report.Stats($"{phase}.frame_delta_ms", samples.Skip(1).Select(s => s.DeltaMs));
        report.Stats($"{phase}.step_ms", samples.Where(s => s.StepMs > 0).Select(s => s.StepMs));
    }
}

// How long a work item waits for the UI thread: the bars' measure of a blocked UI thread.
internal sealed class Heartbeat : IDisposable
{
    private readonly DispatcherQueue _queue;
    private readonly List<double> _latencies = [];
    private volatile bool _running = true;
    private double _worst;
    private bool _worstHadGc;
    private int _waitsWithGc;

    public Heartbeat(DispatcherQueue queue)
    {
        _queue = queue;
        new Thread(Loop) { IsBackground = true, Name = "heartbeat" }.Start();
    }

    public List<double> Take()
    {
        lock (_latencies)
        {
            var copy = _latencies.ToList();
            _latencies.Clear();
            _worst = 0;
            _worstHadGc = false;
            _waitsWithGc = 0;
            return copy;
        }
    }

    // The longest wait since the last Take, whether a GC ran during it, and how many waits held one.
    public string Worst()
    {
        lock (_latencies)
        {
            return string.Create(CultureInfo.InvariantCulture, $"max={_worst:F1} gc_in_max={_worstHadGc} waits_with_gc={_waitsWithGc}");
        }
    }

    public void Dispose() => _running = false;

    private void Loop()
    {
        while (_running)
        {
            var t0 = Clock.Now();
            var collections = GC.CollectionCount(0);
            using var done = new ManualResetEventSlim();
            _queue.TryEnqueue(DispatcherQueuePriority.Normal, () =>
            {
                var ms = Clock.MsSince(t0);
                var gc = GC.CollectionCount(0) != collections;
                lock (_latencies)
                {
                    _latencies.Add(ms);
                    _waitsWithGc += gc ? 1 : 0;
                    if (ms > _worst)
                    {
                        _worst = ms;
                        _worstHadGc = gc;
                    }
                }
                done.Set();
            });
            done.Wait(10000);
            Thread.Sleep(5);
        }
    }
}

internal static class Visuals
{
    public static int Count(DependencyObject root)
    {
        var total = 0;
        var stack = new Stack<DependencyObject>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var node = stack.Pop();
            total++;
            var n = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < n; i++)
            {
                stack.Push(VisualTreeHelper.GetChild(node, i));
            }
        }
        return total;
    }
}

internal static class Mem
{
    public static string Snapshot()
    {
        using var p = Process.GetCurrentProcess();
        p.Refresh();
        return string.Create(CultureInfo.InvariantCulture,
            $"working_set={p.WorkingSet64 / 1048576.0:F1}MB private={p.PrivateMemorySize64 / 1048576.0:F1}MB managed={GC.GetTotalMemory(false) / 1048576.0:F1}MB");
    }
}

internal static partial class Native
{
    public const ushort VkShift = 0x10, VkControl = 0x11, VkMenu = 0x12;
    public const ushort VkPrior = 0x21, VkNext = 0x22, VkEnd = 0x23, VkHome = 0x24, VkLeft = 0x25, VkUp = 0x26, VkRight = 0x27, VkDown = 0x28;

    private const uint InputMouse = 0, InputKeyboard = 1;
    private const uint KeyExtended = 0x0001, KeyUp = 0x0002;
    private const uint MouseMove = 0x0001, MouseLeftDown = 0x0002, MouseLeftUp = 0x0004, MouseAbsolute = 0x8000, MouseVirtualDesk = 0x4000;

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort Vk;
        public ushort Scan;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct InputRecord
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point32
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HighContrastInfo
    {
        public uint Size;
        public uint Flags;
        public IntPtr DefaultScheme;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPels;
        public int YPels;
        public uint ClrUsed;
        public uint ClrImportant;
        public uint Pad0;
        public uint Pad1;
        public uint Pad2;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, InputRecord[] inputs, int size);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attach, uint to, bool on);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentThread();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern bool QueryThreadCycleTime(IntPtr thread, out ulong cycles);

    [DllImport("kernel32.dll")]
    private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    [DllImport("kernel32.dll")]
    private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);

    // The calling thread's cycles, and the CPU time of the machine and of this process in 100 ns units.
    public static (ulong ThreadCycles, long Busy, long Process) CpuNow()
    {
        QueryThreadCycleTime(GetCurrentThread(), out var cycles);
        GetSystemTimes(out var idle, out var kernel, out var user);
        GetProcessTimes(GetCurrentProcess(), out _, out _, out var processKernel, out var processUser);
        return (cycles, kernel + user - idle, processKernel + processUser);
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hwnd, ref Point32 point);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint code, uint mapType);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfoW(uint action, uint param, ref HighContrastInfo info, uint winIni);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);

    [DllImport("gdi32.dll")]
    private static extern int GetDIBits(IntPtr hdc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BitmapInfoHeader info, uint usage);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr hdc);

    private static InputRecord Key(ushort vk, ushort scan, uint flags) => new()
    {
        Type = InputKeyboard,
        Data = new InputUnion { Keyboard = new KeyboardInput { Vk = vk, Scan = scan, Flags = flags } },
    };

    private static bool IsExtended(ushort vk) => vk is >= VkPrior and <= VkDown or 0x2D or 0x2E;

    private static InputRecord VkEvent(ushort vk, bool up) =>
        Key(vk, (ushort)MapVirtualKeyW(vk, 0), (up ? KeyUp : 0) | (IsExtended(vk) ? KeyExtended : 0));

    private static uint Send(params InputRecord[] inputs) => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<InputRecord>());

    public static uint Press(ushort vk) => Send(VkEvent(vk, false), VkEvent(vk, true));

    public static uint Down(ushort vk) => Send(VkEvent(vk, false));

    public static uint Up(ushort vk) => Send(VkEvent(vk, true));

    public static uint Chord(ushort modifier, ushort vk) =>
        Send(VkEvent(modifier, false), VkEvent(vk, false), VkEvent(vk, true), VkEvent(modifier, true));

    private static (int X, int Y) Normalize(int x, int y)
    {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        return ((int)Math.Round((x - vx) * 65535.0 / (vw - 1)), (int)Math.Round((y - vy) * 65535.0 / (vh - 1)));
    }

    private static InputRecord Mouse(int x, int y, uint flags)
    {
        var (nx, ny) = Normalize(x, y);
        return new InputRecord
        {
            Type = InputMouse,
            Data = new InputUnion { Mouse = new MouseInput { Dx = nx, Dy = ny, Flags = flags | MouseAbsolute | MouseVirtualDesk | MouseMove } },
        };
    }

    public static void Click(int x, int y)
    {
        Send(Mouse(x, y, 0));
        Thread.Sleep(30);
        Send(Mouse(x, y, MouseLeftDown), Mouse(x, y, MouseLeftUp));
    }

    public static void MoveTo(int x, int y) => Send(Mouse(x, y, 0));

    public static void LeftDown(int x, int y) => Send(Mouse(x, y, MouseLeftDown));

    public static void LeftUp(int x, int y) => Send(Mouse(x, y, MouseLeftUp));

    public static IntPtr Hwnd(Window window) => WinRT.Interop.WindowNative.GetWindowHandle(window);

    public static bool IsForeground(Window window) => GetForegroundWindow() == Hwnd(window);

    // The system's high contrast on or off, as Settings turns it on, with the scheme Windows last used.
    public static bool SetHighContrast(bool on)
    {
        var info = new HighContrastInfo { Size = (uint)Marshal.SizeOf<HighContrastInfo>(), Flags = on ? 1u : 0u };
        return SystemParametersInfoW(0x0043, info.Size, ref info, 0x01 | 0x02);
    }

    public static (int X, int Y) ToScreen(Window window, UIElement element, Point local)
    {
        var p = element.TransformToVisual(null).TransformPoint(local);
        var scale = element.XamlRoot?.RasterizationScale ?? 1.0;
        var origin = new Point32();
        ClientToScreen(Hwnd(window), ref origin);
        return (origin.X + (int)Math.Round(p.X * scale), origin.Y + (int)Math.Round(p.Y * scale));
    }

    public static (int Width, int Height, byte[] Bgra) CaptureScreen()
    {
        int x = GetSystemMetrics(76), y = GetSystemMetrics(77), w = GetSystemMetrics(78), h = GetSystemMetrics(79);
        var screen = GetDC(IntPtr.Zero);
        var mem = CreateCompatibleDC(screen);
        var bmp = CreateCompatibleBitmap(screen, w, h);
        var old = SelectObject(mem, bmp);
        BitBlt(mem, 0, 0, w, h, screen, x, y, 0x00CC0020 | 0x40000000);
        SelectObject(mem, old);
        var info = new BitmapInfoHeader { Size = 40, Width = w, Height = -h, Planes = 1, BitCount = 32 };
        var bits = new byte[w * h * 4];
        _ = GetDIBits(mem, bmp, 0, (uint)h, bits, ref info, 0);
        DeleteObject(bmp);
        DeleteDC(mem);
        _ = ReleaseDC(IntPtr.Zero, screen);
        return (w, h, bits);
    }

    public static async Task SaveScreenAsync(string path)
    {
        var (w, h, bits) = await Task.Run(CaptureScreen);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)w, (uint)h, 96, 96, bits);
        await encoder.FlushAsync();
        stream.Seek(0);
        var png = new byte[stream.Size];
        using (var reader = new DataReader(stream.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(png);
        }
        await File.WriteAllBytesAsync(path, png);
    }
}

// Hands the app to the out-of-process UIA reader (TablePro.DataGrid.Gate.Uia), which answers through marker files.
internal static class Driver
{
    public static async Task<bool> RequestAsync(RunContext context, string name, int timeoutSeconds = 240)
    {
        var request = Path.Combine(context.OutDir, $"{name}.request");
        var done = Path.Combine(context.OutDir, $"{name}.done");
        File.Delete(done);
        await File.WriteAllTextAsync(request, Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        var sw = Stopwatch.StartNew();
        while (!File.Exists(done) && sw.Elapsed.TotalSeconds < timeoutSeconds)
        {
            await Task.Delay(250);
        }
        File.Delete(request);
        var ok = File.Exists(done);
        context.Report.Line($"{name}.driver_finished", ok);
        context.Report.Line($"{name}.driver_seconds", sw.Elapsed.TotalSeconds);
        return ok;
    }

    // SetForegroundWindow needs the last input, and the Arm64 image leaves another window in front.
    public static async Task EnsureForegroundAsync(RunContext context, UIElement clickTarget)
    {
        var hwnd = Native.Hwnd(context.Window);
        var how = "already";
        for (var i = 0; i < 12 && !Native.IsForeground(context.Window); i++)
        {
            how = "set_foreground";
            Native.Down(Native.VkMenu);
            Native.SetForegroundWindow(hwnd);
            Native.Up(Native.VkMenu);
            await Task.Delay(150);
            if (Native.IsForeground(context.Window))
            {
                break;
            }
            how = "attach_thread_input";
            var foregroundThread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out _);
            var self = Native.GetCurrentThreadId();
            Native.AttachThreadInput(self, foregroundThread, true);
            Native.BringWindowToTop(hwnd);
            Native.SetForegroundWindow(hwnd);
            Native.AttachThreadInput(self, foregroundThread, false);
            await Task.Delay(150);
            if (Native.IsForeground(context.Window))
            {
                continue;
            }
            how = "click";
            var (x, y) = Native.ToScreen(context.Window, clickTarget, new Point(4, 4));
            Native.Click(x, y);
            await Task.Delay(300);
        }
        context.Report.Line("window_is_foreground", Native.IsForeground(context.Window));
        context.Report.Line("foreground_by", how);
    }
}
