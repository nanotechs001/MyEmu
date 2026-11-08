using System.Runtime.InteropServices;
using System.Windows.Interop;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace MyEmu;

/// Android's screen in a child window drawn with Direct3D 11. WPF redraws at most ~60 times a second and
/// its WriteableBitmap cost ~10 ms per 1600×900 frame; this uploads each frame straight into a flip-model
/// swap chain from the frame thread and presents, at whatever rate Android sends. The swap chain is the
/// frame's size and DXGI stretches it to the window, which MainWindow keeps at the screen's aspect ratio.
/// Mouse messages pass through to WPF (HTTRANSPARENT), so touch handling stays in MainWindow.
public sealed class D3DScreen : HwndHost
{
    IntPtr hwnd;
    ID3D11Device? device;
    ID3D11DeviceContext? context;
    IDXGISwapChain1? swapChain;
    int width, height;
    readonly object sync = new();

    protected override HandleRef BuildWindowCore(HandleRef parent)
    {
        hwnd = CreateWindowEx(0, ClassName, "", WsChild | WsVisible | WsClipSiblings, 0, 0, 1, 1, parent.Handle, 0, 0, 0);
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport,
            [FeatureLevel.Level_11_0], out device, out context).CheckError();
        return new HandleRef(this, hwnd);
    }

    protected override void DestroyWindowCore(HandleRef window)
    {
        lock (sync)
        {
            swapChain?.Dispose(); swapChain = null;
            context?.Dispose(); context = null;
            device?.Dispose(); device = null;
        }
        DestroyWindow(window.Handle);
    }

    /// Shows one RGBA frame. Call from one thread at a time (the frame stream).
    public void Present(ReadOnlySpan<byte> rgba, int w, int h)
    {
        lock (sync)
        {
            if (device == null || context == null) return;
            if (swapChain == null)
            {
                using var dxgi = device.QueryInterface<IDXGIDevice>();
                using var adapter = dxgi.GetAdapter();
                using var factory = adapter.GetParent<IDXGIFactory2>();
                swapChain = factory.CreateSwapChainForHwnd(device, hwnd, new SwapChainDescription1
                {
                    Width = (uint)w, Height = (uint)h, Format = Format.R8G8B8A8_UNorm, BufferCount = 2,
                    BufferUsage = Usage.RenderTargetOutput, SampleDescription = new SampleDescription(1, 0),
                    Scaling = Scaling.Stretch, SwapEffect = SwapEffect.FlipDiscard, AlphaMode = AlphaMode.Ignore,
                });
                factory.MakeWindowAssociation(hwnd, WindowAssociationFlags.IgnoreAll);
                (width, height) = (w, h);
            }
            else if (w != width || h != height) // rotation
            {
                swapChain.ResizeBuffers(2, (uint)w, (uint)h, Format.R8G8B8A8_UNorm, SwapChainFlags.None).CheckError();
                (width, height) = (w, h);
            }
            using var back = swapChain.GetBuffer<ID3D11Texture2D>(0);
            context.UpdateSubresource(rgba[..(w * h * 4)], back, 0, (uint)(w * 4), 0);
            swapChain.Present(0, PresentFlags.None);
        }
    }

    // --- Win32: a bare child window class whose clicks go to the WPF window underneath.

    const int WsChild = 0x40000000, WsVisible = 0x10000000, WsClipSiblings = 0x04000000;
    const string ClassName = "MyEmuD3DScreen";
    static readonly ChildWndProc Proc = (h, msg, w, l) => msg == 0x84 /* WM_NCHITTEST */ ? -1 /* HTTRANSPARENT */ : DefWindowProc(h, msg, w, l);

    static D3DScreen()
    {
        var wc = new WndClassEx
        {
            Size = Marshal.SizeOf<WndClassEx>(), WndProc = Marshal.GetFunctionPointerForDelegate(Proc),
            Instance = Marshal.GetHINSTANCE(typeof(D3DScreen).Module), ClassName = ClassName,
        };
        RegisterClassEx(ref wc);
    }

    delegate nint ChildWndProc(IntPtr hwnd, uint msg, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WndClassEx
    {
        public int Size, Style;
        public IntPtr WndProc;
        public int ClsExtra, WndExtra;
        public IntPtr Instance, Icon, Cursor, Background;
        public string? MenuName, ClassName;
        public IntPtr IconSm;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassEx(ref WndClassEx wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowEx(int exStyle, string cls, string name, int style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern nint DefWindowProc(IntPtr hwnd, uint msg, nint wParam, nint lParam);
}
