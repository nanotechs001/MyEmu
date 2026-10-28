// A running MuMu Player instance, reached through MuMu's own SDK (external_renderer_ipc.dll: screen and
// touches, no adb) and its command-line manager (which app is in front). Nothing of MuMu is copied or changed.
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace MyEmu.AutoPots;

/// MuMu's capture: RGBA rows, bottom row first.
public sealed class NemuFrame(byte[] pixels, int width, int height) : IPixelFrame
{
    public byte[] Pixels { get; } = pixels;
    public int Width { get; } = width;
    public int Height { get; } = height;

    public int Rgb(int x, int y)
    {
        int i = ((Height - 1 - y) * Width + x) * 4;
        return Pixels[i] << 16 | Pixels[i + 1] << 8 | Pixels[i + 2];
    }
}

public sealed class MuMu : IDisposable
{
    const string Sdk = "external_renderer_ipc.dll";

    [DllImport(Sdk, CharSet = CharSet.Unicode)] static extern int nemu_connect(string path, int index);
    [DllImport(Sdk)] static extern void nemu_disconnect(int handle);
    [DllImport(Sdk)] static extern int nemu_capture_display(int handle, uint displayId, int bufferSize, out int width, out int height, byte[]? pixels);
    [DllImport(Sdk)] static extern int nemu_input_event_touch_down(int handle, int displayId, int x, int y);
    [DllImport(Sdk)] static extern int nemu_input_event_touch_up(int handle, int displayId);

    public string Root { get; }
    public int Instance { get; }
    readonly object gate = new(); // capture and touches share the SDK handle
    int handle;
    byte[] buffer = [];
    int width, height;

    static string? sdkPath;

    static MuMu()
    {
        NativeLibrary.SetDllImportResolver(typeof(MuMu).Assembly, (name, _, _) =>
            name == Sdk && sdkPath != null ? NativeLibrary.Load(sdkPath) : IntPtr.Zero);
    }

    public MuMu(string root, int instance)
    {
        Root = root;
        Instance = instance;
        sdkPath = Path.Combine(root, @"nx_device\12.0\shell\sdk", Sdk);
    }

    /// MuMu Player 12's install folder, from its uninstall entry (or the default path).
    public static string? FindRoot()
    {
        foreach (var hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
            foreach (var view in new[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
            {
                using var key = hive.OpenSubKey(view);
                if (key == null) continue;
                foreach (var name in key.GetSubKeyNames())
                {
                    using var app = key.OpenSubKey(name);
                    if (app?.GetValue("DisplayName") is not string display || !display.StartsWith("MuMuPlayer")) continue;
                    if (app.GetValue("UninstallString") is string uninstall)
                    {
                        var dir = Path.GetDirectoryName(uninstall.Trim('"'));
                        if (dir != null && File.Exists(Path.Combine(dir, @"nx_device\12.0\shell\sdk", Sdk))) return dir;
                    }
                }
            }
        const string fallback = @"C:\Program Files\Netease\MuMuPlayerGlobal-12.0";
        return File.Exists(Path.Combine(fallback, @"nx_device\12.0\shell\sdk", Sdk)) ? fallback : null;
    }

    public bool IsConnected { get { lock (gate) return handle != 0; } }

    bool EnsureConnected()
    {
        if (handle != 0) return true;
        handle = nemu_connect(Root, Instance);
        if (handle == 0) return false;
        if (nemu_capture_display(handle, 0, 0, out width, out height, null) != 0 || width <= 0 || height <= 0)
        {
            Drop();
            return false;
        }
        if (buffer.Length != width * height * 4) buffer = new byte[width * height * 4];
        return true;
    }

    void Drop()
    {
        if (handle != 0) nemu_disconnect(handle);
        handle = 0;
    }

    /// The latest frame, or null when the instance isn't running. The frame reuses one buffer: it's
    /// valid until the next Capture (use CaptureCopy to keep one).
    public NemuFrame? Capture()
    {
        lock (gate)
        {
            if (!EnsureConnected()) return null;
            if (nemu_capture_display(handle, 0, buffer.Length, out int w, out int h, buffer) != 0 || w != width || h != height)
            {
                Drop(); // stopped, restarted or resized: reconnect on the next call
                return null;
            }
            return new NemuFrame(buffer, width, height);
        }
    }

    public NemuFrame? CaptureCopy()
    {
        lock (gate)
        {
            var frame = Capture();
            return frame == null ? null : new NemuFrame((byte[])frame.Pixels.Clone(), frame.Width, frame.Height);
        }
    }

    public void Touch(int x, int y, bool down)
    {
        lock (gate)
        {
            if (!EnsureConnected()) return;
            if (down) nemu_input_event_touch_down(handle, 0, x, y); else nemu_input_event_touch_up(handle, 0);
        }
    }

    /// The Android package in front, through MuMu's own shell (no adb, so it can't clash with an
    /// Android SDK's adb server). Null when the instance isn't running.
    public string? ForegroundApp()
    {
        var manager = Path.Combine(Root, @"nx_main\MuMuManager.exe");
        var start = new ProcessStartInfo(manager)
        {
            ArgumentList = { "sh", "-v", Instance.ToString(), "-c", "dumpsys activity activities | grep -m1 topResumedActivity" },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        try
        {
            using var process = Process.Start(start)!;
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(3000)) { process.Kill(); return null; }
            // topResumedActivity=ActivityRecord{1a2b3c u0 com.com.Xerion/.CQ2ClientActivity t12}
            var line = output.Result;
            int u0 = line.IndexOf(" u0 ", StringComparison.Ordinal);
            if (u0 < 0) return null;
            int slash = line.IndexOf('/', u0);
            return slash < 0 ? null : line[(u0 + 4)..slash];
        }
        catch (Exception) { return null; }
    }

    public void Dispose() { lock (gate) Drop(); }
}
