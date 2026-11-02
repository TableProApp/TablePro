using System.Runtime.InteropServices;
using TerraFX.Interop;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Graphics;

internal static unsafe class NativeCom
{
    public static void Check(HRESULT result)
    {
        if (result.FAILED)
        {
            Marshal.ThrowExceptionForHR(result.Value);
        }
    }

    public static void Release<T>(ref T* pointer)
        where T : unmanaged
    {
        if (pointer is not null)
        {
            ((IUnknown*)pointer)->Release();
            pointer = null;
        }
    }

    public static Guid* Iid<T>()
        where T : unmanaged, INativeGuid => __uuidof<T>();
}
