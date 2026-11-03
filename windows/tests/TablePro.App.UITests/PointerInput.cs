using System.Drawing;
using System.Runtime.InteropServices;

namespace TablePro.App.UITests;

// Mouse input as the hardware sends it, through SendInput, in absolute coordinates on the primary display.
internal static partial class PointerInput
{
    private const uint InputMouse = 0;
    private const uint Moved = 0x0001;
    private const uint LeftDown = 0x0002;
    private const uint LeftUp = 0x0004;
    private const uint Absolute = 0x8000;
    private const int ScreenWidth = 0;
    private const int ScreenHeight = 1;

    public static void Move(Point point)
    {
        var width = GetSystemMetrics(ScreenWidth);
        var height = GetSystemMetrics(ScreenHeight);
        Send(new MouseInput
        {
            X = (int)((point.X * 65535L) / Math.Max(1, width - 1)),
            Y = (int)((point.Y * 65535L) / Math.Max(1, height - 1)),
            Flags = Moved | Absolute,
        });
    }

    public static void Button(bool down) => Send(new MouseInput { Flags = down ? LeftDown : LeftUp });

    private static void Send(MouseInput mouse)
    {
        Input[] inputs = [new Input { Type = InputMouse, Mouse = mouse }];
        if (SendInput(1, inputs, Marshal.SizeOf<Input>()) != 1)
        {
            throw new InvalidOperationException($"SendInput refused the input (error {Marshal.GetLastPInvokeError()}).");
        }
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial uint SendInput(uint count, [In] Input[] inputs, int size);

    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int index);

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint Data;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }
}
