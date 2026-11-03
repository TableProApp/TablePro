using System.Runtime.InteropServices;
using Microsoft.Graphics.DirectX;
using Microsoft.UI.Composition;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using Windows.Graphics;
using static TerraFX.Interop.DirectX.D2D1_DEVICE_CONTEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2DERR;
using static TerraFX.Interop.DirectX.DirectX;
using static TerraFX.Interop.DirectX.DWRITE_FACTORY_TYPE;
using static TerraFX.Interop.DirectX.DXGI;

namespace TablePro.Graphics;

// The Windows App SDK's interop IIDs and ICompositorInterop layout differ from the system's ones.
internal sealed unsafe class SurfaceDevice : IDisposable
{
    private static readonly Guid CompositorInteropIid = new("FAB19398-6D19-4D8A-B752-8F096C396069");
    private static readonly Guid GraphicsDeviceInteropIid = new("4AFA8030-BC70-4B0C-B1C7-6E69F933DC83");
    private static readonly Guid DrawingSurfaceInteropIid = new("2D6355C2-AD57-4EAE-92E4-4C3EFF65D578");

    private readonly bool _forceSoftware;
    private RenderDevice _device;
    private ID2D1DeviceContext* _resources;
    private IDWriteFactory* _dwrite;

    public SurfaceDevice(Compositor compositor, bool forceSoftware)
    {
        ArgumentNullException.ThrowIfNull(compositor);
        _forceSoftware = forceSoftware;
        _device = new RenderDevice(forceSoftware, multithreaded: true);
        _resources = CreateContext(_device);
        IDWriteFactory* dwrite;
        NativeCom.Check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, NativeCom.Iid<IDWriteFactory>(), (IUnknown**)&dwrite));
        _dwrite = dwrite;
        Graphics = CreateGraphicsDevice(compositor, _device.Direct2D);
    }

    public CompositionGraphicsDevice Graphics { get; }

    // Bumped each time the device is replaced; what was made on the old one is made again.
    public int Generation { get; private set; }

    public int DevicesLost { get; private set; }

    public bool IsSoftware => _device.IsSoftware;

    public string AdapterName => _device.AdapterName;

    public IDWriteFactory* DWrite => _dwrite;

    public ID2D1Device* Direct2D => _device.Direct2D;

    // For brushes and other device resources, which every context of the same Direct2D device can use.
    public ID2D1DeviceContext* Resources => _resources;

    // A test seam: the next draw fails as a removed device does.
    public bool FailNextDraw { get; set; }

    public static bool IsDeviceLost(HRESULT result) =>
        result == DXGI_ERROR_DEVICE_REMOVED || result == DXGI_ERROR_DEVICE_RESET || result == DXGI_ERROR_DEVICE_HUNG
        || result == D2DERR_RECREATE_TARGET;

    public DrawingSurface CreateSurface(SizeInt32 pixels) =>
        new(this, Graphics.CreateDrawingSurface2(
            pixels, DirectXPixelFormat.B8G8R8A8UIntNormalized, DirectXAlphaMode.Premultiplied));

    // Surfaces keep their objects and lose their pixels.
    public void Recover()
    {
        DevicesLost++;
        NativeCom.Release(ref _resources);
        _device.Dispose();
        _device = new RenderDevice(_forceSoftware, multithreaded: true);
        _resources = CreateContext(_device);
        var graphics = ((WinRT.IWinRTObject)Graphics).NativeObject.ThisPtr;
        var iid = GraphicsDeviceInteropIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(graphics, in iid, out var interop));
        try
        {
            NativeCom.Check(((TerraFX.Interop.WinRT.ICompositionGraphicsDeviceInterop*)interop)->SetRenderingDevice(
                (IUnknown*)_device.Direct2D));
        }
        finally
        {
            Marshal.Release(interop);
        }
        Generation++;
    }

    public void Dispose()
    {
        NativeCom.Release(ref _resources);
        NativeCom.Release(ref _dwrite);
        _device.Dispose();
        Graphics.Dispose();
    }

    internal static nint DrawingInterop(CompositionDrawingSurface surface)
    {
        var native = ((WinRT.IWinRTObject)surface).NativeObject.ThisPtr;
        var iid = DrawingSurfaceInteropIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(native, in iid, out var interop));
        return interop;
    }

    private static ID2D1DeviceContext* CreateContext(RenderDevice device)
    {
        ID2D1DeviceContext* context;
        NativeCom.Check(device.Direct2D->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context));
        return context;
    }

    private static CompositionGraphicsDevice CreateGraphicsDevice(Compositor compositor, ID2D1Device* device)
    {
        var native = ((WinRT.IWinRTObject)compositor).NativeObject.ThisPtr;
        var iid = CompositorInteropIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(native, in iid, out var interop));
        void* graphics = null;
        try
        {
            // Windows App SDK's ICompositorInterop has CreateGraphicsDevice alone, right after IUnknown.
            var table = *(void***)interop;
            var create = (delegate* unmanaged[MemberFunction]<nint, IUnknown*, void**, int>)table[3];
            Marshal.ThrowExceptionForHR(create(interop, (IUnknown*)device, &graphics));
            return CompositionGraphicsDevice.FromAbi((nint)graphics);
        }
        finally
        {
            Marshal.Release(interop);
            if (graphics is not null)
            {
                Marshal.Release((nint)graphics);
            }
        }
    }
}

// Begin applies the surface's update offset, which can be anywhere in a shared atlas, so callers draw from (0, 0).
internal sealed unsafe class DrawingSurface : IDisposable
{
    private readonly SurfaceDevice _device;
    private nint _interop;

    public DrawingSurface(SurfaceDevice device, CompositionDrawingSurface surface)
    {
        _device = device;
        Surface = surface;
        _interop = SurfaceDevice.DrawingInterop(surface);
        Pixels = surface.SizeInt32;
    }

    public CompositionDrawingSurface Surface { get; }

    public SizeInt32 Pixels { get; private set; }

    public void Resize(SizeInt32 pixels)
    {
        NativeCom.Check(Interop->Resize(new SIZE { cx = pixels.Width, cy = pixels.Height }));
        Pixels = pixels;
    }

    // Null when the device was lost; the device has been moved to a new one and the caller draws again later.
    public ID2D1DeviceContext* Begin(float scale)
    {
        ID2D1DeviceContext* context = null;
        POINT offset = default;
        var iid = NativeCom.Iid<ID2D1DeviceContext>();
        HRESULT result = _device.FailNextDraw ? D2DERR_RECREATE_TARGET : Interop->BeginDraw(null, iid, (void**)&context, &offset);
        if (result.FAILED)
        {
            _device.FailNextDraw = false;
            if (SurfaceDevice.IsDeviceLost(result))
            {
                _device.Recover();
                return null;
            }
            NativeCom.Check(result);
        }
        context->SetDpi(96 * scale, 96 * scale);
        var translate = new D2D_MATRIX_3X2_F { _11 = 1, _22 = 1, _31 = offset.x / scale, _32 = offset.y / scale };
        context->SetTransform(&translate);
        return context;
    }

    // False when the device was lost while drawing.
    public bool End(ID2D1DeviceContext* context)
    {
        HRESULT result = Interop->EndDraw();
        context->Release();
        if (result.SUCCEEDED)
        {
            return true;
        }
        if (SurfaceDevice.IsDeviceLost(result))
        {
            _device.Recover();
            return false;
        }
        NativeCom.Check(result);
        return false;
    }

    public void Dispose()
    {
        if (_interop != 0)
        {
            Marshal.Release(_interop);
            _interop = 0;
        }
        Surface.Dispose();
    }

    private TerraFX.Interop.WinRT.ICompositionDrawingSurfaceInterop* Interop =>
        (TerraFX.Interop.WinRT.ICompositionDrawingSurfaceInterop*)_interop;
}
