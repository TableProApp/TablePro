using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.DirectX.D2D1_ALPHA_MODE;
using static TerraFX.Interop.DirectX.D2DERR;
using static TerraFX.Interop.DirectX.D2D1_BITMAP_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_DEVICE_CONTEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_FACTORY_TYPE;
using static TerraFX.Interop.DirectX.D3D_DRIVER_TYPE;
using static TerraFX.Interop.DirectX.D3D11_CREATE_DEVICE_FLAG;
using static TerraFX.Interop.DirectX.DirectX;
using static TerraFX.Interop.DirectX.DWRITE_FACTORY_TYPE;
using static TerraFX.Interop.DirectX.DXGI;
using static TerraFX.Interop.DirectX.DXGI_ALPHA_MODE;
using static TerraFX.Interop.DirectX.DXGI_FORMAT;
using static TerraFX.Interop.DirectX.DXGI_SCALING;
using static TerraFX.Interop.DirectX.DXGI_SWAP_CHAIN_FLAG;
using static TerraFX.Interop.DirectX.DXGI_SWAP_EFFECT;
using static TerraFX.Interop.Windows.Windows;
using static TerraFX.Interop.Windows.E;

namespace TablePro.Editor.Rendering;

// Direct3D 11 for the swap chain, Direct2D on top of it for drawing, DirectWrite for text. The swap chain belongs to
// a SwapChainPanel, so XAML composes it with the rest of the window and nothing is copied through a XAML surface.
internal sealed unsafe class GraphicsDevice : IDisposable
{
    // ISwapChainPanelNative as WinUI 3 declares it (microsoft.ui.xaml.media.dxinterop.h). The system XAML one has
    // another IID, so TerraFX's struct is used only for its vtable.
    private static readonly Guid SwapChainPanelNativeIid = new("63aad0b8-7c24-40ff-85a8-640d944cc325");

    private ID3D11Device* _d3d;
    private IDXGIFactory2* _dxgiFactory;
    private ID2D1Factory1* _d2dFactory;
    private ID2D1Device* _d2dDevice;
    private ID2D1DeviceContext* _context;
    private IDXGISwapChain1* _swapChain;
    private ID2D1Bitmap1* _target;
    private IDWriteFactory* _dwrite;
    private HANDLE _frameReady;
    private float _scaleX = 1;
    private float _scaleY = 1;

    public GraphicsDevice(bool forceSoftware)
    {
        CreateDevice(forceSoftware);
        IDWriteFactory* dwrite;
        NativeCom.Check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, NativeCom.Iid<IDWriteFactory>(), (IUnknown**)&dwrite));
        _dwrite = dwrite;
    }

    public bool IsSoftware { get; private set; }

    public string AdapterName { get; private set; } = string.Empty;

    public int PixelWidth { get; private set; }

    public int PixelHeight { get; private set; }

    public ID2D1DeviceContext* Context => _context;

    public IDWriteFactory* DWrite => _dwrite;

    public bool HasTarget => _target is not null;

    public void Attach(SwapChainPanel panel, int pixelWidth, int pixelHeight, float scaleX, float scaleY)
    {
        PixelWidth = Math.Max(1, pixelWidth);
        PixelHeight = Math.Max(1, pixelHeight);
        _scaleX = scaleX;
        _scaleY = scaleY;
        var description = new DXGI_SWAP_CHAIN_DESC1
        {
            Width = (uint)PixelWidth,
            Height = (uint)PixelHeight,
            Format = DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc = new DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
            BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount = 3,
            Scaling = DXGI_SCALING_STRETCH,
            SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED,
            Flags = (uint)DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
        };
        IDXGISwapChain1* swapChain;
        NativeCom.Check(_dxgiFactory->CreateSwapChainForComposition((IUnknown*)_d3d, &description, null, &swapChain));
        _swapChain = swapChain;
        // Two frames may wait for the screen. A frame starts only when the swap chain can take it, so Present never
        // blocks the UI thread, and input drawn right after a frame still reaches the next refresh.
        IDXGISwapChain2* swapChain2;
        NativeCom.Check(_swapChain->QueryInterface(NativeCom.Iid<IDXGISwapChain2>(), (void**)&swapChain2));
        swapChain2->SetMaximumFrameLatency(2);
        _frameReady = swapChain2->GetFrameLatencyWaitableObject();
        swapChain2->Release();
        ApplyScale();

        var inspectable = ((WinRT.IWinRTObject)panel).NativeObject.ThisPtr;
        var iid = SwapChainPanelNativeIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(inspectable, in iid, out var native));
        try
        {
            NativeCom.Check(((TerraFX.Interop.WinRT.ISwapChainPanelNative*)native)->SetSwapChain((IDXGISwapChain*)_swapChain));
        }
        finally
        {
            Marshal.Release(native);
        }
        CreateTarget();
    }

    public void Resize(int pixelWidth, int pixelHeight, float scaleX, float scaleY)
    {
        if (_swapChain is null)
        {
            return;
        }
        pixelWidth = Math.Max(1, pixelWidth);
        pixelHeight = Math.Max(1, pixelHeight);
        if (pixelWidth == PixelWidth && pixelHeight == PixelHeight && scaleX == _scaleX && scaleY == _scaleY)
        {
            return;
        }
        PixelWidth = pixelWidth;
        PixelHeight = pixelHeight;
        _scaleX = scaleX;
        _scaleY = scaleY;
        _context->SetTarget(null);
        NativeCom.Release(ref _target);
        NativeCom.Check(_swapChain->ResizeBuffers(0, (uint)pixelWidth, (uint)pixelHeight, DXGI_FORMAT_UNKNOWN,
            (uint)DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT));
        ApplyScale();
        CreateTarget();
    }

    // True when the swap chain can take a frame now. It takes the swap chain's signal, so a true is followed by a frame.
    public bool TryBeginFrame() => _frameReady == HANDLE.NULL || WaitForSingleObjectEx(_frameReady, 0, BOOL.FALSE) == WAIT.WAIT_OBJECT_0;

    public void BeginDraw() => _context->BeginDraw();

    // False when the device was lost; the caller drops what it made on the device and draws again.
    public bool EndDrawAndPresent()
    {
        var drawn = _context->EndDraw();
        if (drawn == D2DERR_RECREATE_TARGET)
        {
            return false;
        }
        NativeCom.Check(drawn);
        var presented = _swapChain->Present(1, 0);
        if (presented == DXGI_ERROR_DEVICE_REMOVED || presented == DXGI_ERROR_DEVICE_RESET)
        {
            return false;
        }
        NativeCom.Check(presented);
        return true;
    }

    public void Dispose()
    {
        if (_frameReady != HANDLE.NULL)
        {
            CloseHandle(_frameReady);
            _frameReady = HANDLE.NULL;
        }
        if (_context is not null)
        {
            _context->SetTarget(null);
        }
        NativeCom.Release(ref _target);
        NativeCom.Release(ref _swapChain);
        NativeCom.Release(ref _context);
        NativeCom.Release(ref _d2dDevice);
        NativeCom.Release(ref _d2dFactory);
        NativeCom.Release(ref _dxgiFactory);
        NativeCom.Release(ref _d3d);
        NativeCom.Release(ref _dwrite);
    }

    private void CreateDevice(bool forceSoftware)
    {
        var flags = (uint)D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        ID3D11Device* device = null;
        HRESULT created = forceSoftware ? E_FAIL : D3D11CreateDevice(null, D3D_DRIVER_TYPE_HARDWARE, HMODULE.NULL, flags, null, 0,
            D3D11.D3D11_SDK_VERSION, &device, null, null);
        if (created.FAILED)
        {
            NativeCom.Check(D3D11CreateDevice(null, D3D_DRIVER_TYPE_WARP, HMODULE.NULL, flags, null, 0, D3D11.D3D11_SDK_VERSION,
                &device, null, null));
            IsSoftware = true;
        }
        _d3d = device;

        IDXGIDevice* dxgiDevice;
        NativeCom.Check(_d3d->QueryInterface(NativeCom.Iid<IDXGIDevice>(), (void**)&dxgiDevice));
        try
        {
            IDXGIAdapter* adapter;
            NativeCom.Check(dxgiDevice->GetAdapter(&adapter));
            DXGI_ADAPTER_DESC description;
            if (adapter->GetDesc(&description).SUCCEEDED)
            {
                AdapterName = new string((char*)&description.Description);
                // The Basic Render Driver is WARP behind a hardware device type, as on VMs without a GPU.
                IsSoftware |= description.VendorId == 0x1414 && description.DeviceId == 0x8c;
            }
            IDXGIFactory2* factory;
            NativeCom.Check(adapter->GetParent(NativeCom.Iid<IDXGIFactory2>(), (void**)&factory));
            _dxgiFactory = factory;
            adapter->Release();

            var options = new D2D1_FACTORY_OPTIONS();
            ID2D1Factory1* d2dFactory;
            NativeCom.Check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, NativeCom.Iid<ID2D1Factory1>(), &options,
                (void**)&d2dFactory));
            _d2dFactory = d2dFactory;
            ID2D1Device* d2dDevice;
            NativeCom.Check(_d2dFactory->CreateDevice(dxgiDevice, &d2dDevice));
            _d2dDevice = d2dDevice;
            ID2D1DeviceContext* context;
            NativeCom.Check(_d2dDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context));
            _context = context;
        }
        finally
        {
            dxgiDevice->Release();
        }
    }

    // The panel shows the buffer at its own scale, so the buffer is drawn in pixels and shrunk back by the scale.
    private void ApplyScale()
    {
        IDXGISwapChain2* swapChain2;
        if (_swapChain->QueryInterface(NativeCom.Iid<IDXGISwapChain2>(), (void**)&swapChain2).SUCCEEDED)
        {
            var matrix = new DXGI_MATRIX_3X2_F { _11 = 1 / _scaleX, _22 = 1 / _scaleY };
            swapChain2->SetMatrixTransform(&matrix);
            swapChain2->Release();
        }
    }

    private void CreateTarget()
    {
        IDXGISurface* surface;
        NativeCom.Check(_swapChain->GetBuffer(0, NativeCom.Iid<IDXGISurface>(), (void**)&surface));
        try
        {
            var properties = new D2D1_BITMAP_PROPERTIES1
            {
                pixelFormat = new D2D1_PIXEL_FORMAT { format = DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED },
                dpiX = 96 * _scaleX,
                dpiY = 96 * _scaleY,
                bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            };
            ID2D1Bitmap1* target;
            NativeCom.Check(_context->CreateBitmapFromDxgiSurface(surface, &properties, &target));
            _target = target;
        }
        finally
        {
            surface->Release();
        }
        _context->SetTarget((ID2D1Image*)_target);
        _context->SetDpi(96 * _scaleX, 96 * _scaleY);
    }
}
