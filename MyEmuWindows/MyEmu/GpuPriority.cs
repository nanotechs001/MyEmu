using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Vortice.DXGI;

namespace MyEmu;

/// "GPU priority" (a Windows-only request, README): on PCs with a dedicated GPU, MyEmu and the engine run
/// on it ("High performance" in Windows' graphics settings) and ahead of other apps for GPU and CPU time,
/// with Windows' power throttling (EcoQoS) off so the engine stays on the fast cores. Off restores defaults.
public static class GpuPriority
{
    const string PreferencesKey = @"Software\Microsoft\DirectX\UserGpuPreferences";
    const string HighPerformance = "GpuPreference=2;";
    const string EngineProcess = "qemu-system-x86_64-headless";

    /// A hardware GPU with its own memory (1 GB+; integrated ones report ~128 MB). Hybrid laptops count.
    public static bool HasDedicatedGpu { get; } = FindDedicatedGpu();

    static bool FindDedicatedGpu()
    {
        try
        {
            using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
            for (uint i = 0; factory.EnumAdapters1(i, out var adapter).Success; i++)
                using (adapter)
                {
                    var desc = adapter.Description1;
                    if ((desc.Flags & AdapterFlags.Software) == 0 && (ulong)desc.DedicatedVideoMemory >= 1UL << 30) return true;
                }
        }
        catch (Exception e) { Debug.WriteLine($"GPU check failed: {e.Message}"); }
        return false;
    }

    /// The programs Windows' per-app GPU preference applies to: MyEmu's window and the engine's renderer.
    static IEnumerable<string> Programs =>
    [
        Environment.ProcessPath!, Engine.EmulatorExe,
        Path.Combine(Engine.Sdk, "emulator", "qemu", "windows-x86_64", EngineProcess + ".exe"),
    ];

    /// Sets or clears the GPU preference (read when a program starts) and the running engines' priority.
    public static void Apply(bool on)
    {
        if (!HasDedicatedGpu) return;
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(PreferencesKey);
            foreach (var program in Programs)
                if (on) key.SetValue(program, HighPerformance);
                else if (key.GetValue(program) as string == HighPerformance) key.DeleteValue(program); // only what MyEmu set
        }
        catch (Exception e) { Debug.WriteLine($"GPU preference failed: {e.Message}"); }
        foreach (var process in Process.GetProcessesByName(EngineProcess).Append(Process.GetCurrentProcess()))
            using (process)
            {
                try
                {
                    if (process.Id != Environment.ProcessId && !(process.MainModule?.FileName ?? "").StartsWith(Engine.Sdk, StringComparison.OrdinalIgnoreCase))
                        continue; // another app's emulator
                    process.PriorityClass = on ? ProcessPriorityClass.AboveNormal : ProcessPriorityClass.Normal;
                    // High needs a privilege MyEmu may not have; Above normal doesn't.
                    if (!on || D3DKMTSetProcessSchedulingPriorityClass(process.Handle, High) != 0)
                        D3DKMTSetProcessSchedulingPriorityClass(process.Handle, on ? AboveNormal : Normal);
                    var throttling = new PowerThrottlingState { Version = 1, ControlMask = on ? 1u : 0u, StateMask = 0 };
                    SetProcessInformation(process.Handle, ProcessPowerThrottling, ref throttling, (uint)Marshal.SizeOf<PowerThrottlingState>());
                }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { } // exited meanwhile
            }
    }

    // D3DKMT_SCHEDULINGPRIORITYCLASS
    const int Normal = 2, AboveNormal = 3, High = 4;
    [DllImport("gdi32.dll")] static extern int D3DKMTSetProcessSchedulingPriorityClass(nint process, int priority);

    const int ProcessPowerThrottling = 4; // PROCESS_INFORMATION_CLASS
    /// ControlMask 1 = execution speed managed by MyEmu, StateMask 0 = not throttled; both 0 = Windows decides.
    [StructLayout(LayoutKind.Sequential)] struct PowerThrottlingState { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll")] static extern bool SetProcessInformation(nint process, int infoClass, ref PowerThrottlingState info, uint size);
}
