using System.IO;
using System.Windows;

namespace MyEmu;

public static class App
{
    /// Opens instance 1; the others start from its Instances list (or over MCP).
    [STAThread]
    public static void Main()
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown }; // last instance window closes it
        app.Startup += async (_, _) =>
        {
            InstanceManager.Open(Instance.Main.Id);
            if (AndroidOptions.Shared.AiControl) await InstanceManager.SetAiControlAsync(true);
        };
        app.Run();
    }
}

/// Runs each instance in its own window: a window open means that instance's Android is starting or
/// running (Mac: InstanceManager.swift). Also owns what's app-wide: the options and the MCP server.
public static class InstanceManager
{
    public static InstanceList List { get; } = InstanceList.Load();
    static readonly Dictionary<string, MainWindow> windows = [];
    /// The list, open windows, a clone in progress or AI control changed.
    public static event Action? Changed;
    /// Android options changed in one window: the others apply them too.
    public static event Action<MainWindow>? OptionsChanged;

    /// Set while an AVD is being copied; creating, cloning and deleting wait for it.
    public static string? Busy { get; private set; }

    public static MainWindow? Window(string id) => windows.GetValueOrDefault(id);

    static McpInstanceState StoppedState(Instance i)
    {
        var device = DeviceSettings.Load(i.Id);
        return new(i.Id, i.Name, false, null, "Stopped", null, device.Profile, device.GameSpeed);
    }

    /// Shows the instance's window, opening it (which starts its Android) if needed.
    public static void Open(string id)
    {
        if (windows.TryGetValue(id, out var open))
        {
            if (open.WindowState == WindowState.Minimized) open.WindowState = WindowState.Normal;
            open.Activate();
            return;
        }
        if (List.Find(id) is not { } instance) return;
        var window = new MainWindow(instance);
        windows[id] = window;
        window.Closed += (_, _) =>
        {
            windows.Remove(id);
            Changed?.Invoke();
            if (windows.Count == 0) Application.Current.Shutdown();
        };
        window.Show();
        Changed?.Invoke();
    }

    public static Instance? Create()
    {
        if (Busy != null || List.Add() is not { } instance) return null;
        List.Save();
        Changed?.Invoke();
        return instance;
    }

    /// A new instance that's a copy of a stopped one, its Android data included. Null at the limit.
    public static async Task<Instance?> CloneAsync(string id)
    {
        if (Busy != null || List.Find(id) is not { } source || windows.ContainsKey(id) || !List.CanAdd) return null;
        var target = new Instance("", "", List.Instances.Max(i => i.Number) + 1); // the number Add gives next
        Busy = $"Copying {source.Name}…";
        Changed?.Invoke();
        var targets = Enum.GetValues<DeviceProfile>().Select(p => (Source: source.Avd(p), Target: target.Avd(p))).ToList();
        var leftOver = targets.Where(t => AvdFiles.Exists(t.Target) || Directory.Exists(Path.Combine(AvdFiles.Root, $"{t.Target}.avd"))).ToList();
        try
        {
            if (leftOver.Count > 0) throw new IOException($"{leftOver[0].Target} already exists in {AvdFiles.Root}; move it away first.");
            foreach (var (from, to) in targets) await AvdFiles.CloneAsync(from, to); // both Androids (an unused one is skipped)
            var copy = List.Add($"{source.Name} copy")!;
            DeviceSettings.Load(source.Id).Save(copy.Id);
            List.Save();
            return copy;
        }
        catch when (leftOver.Count == 0)
        {
            foreach (var (_, to) in targets) AvdFiles.Delete(to); // only what this clone made (none existed before)
            throw;
        }
        finally
        {
            Busy = null;
            Changed?.Invoke();
        }
    }

    public static void Rename(string id, string name)
    {
        List.Rename(id, name);
        List.Save();
        if (windows.TryGetValue(id, out var window) && List.Find(id) is { } renamed) window.Title = $"MyEmu · {renamed.Name}";
        Changed?.Invoke();
    }

    /// Deletes a stopped instance and all its Android data. Instance 1 stays.
    public static void Delete(string id)
    {
        if (Busy != null || List.Find(id) is not { Number: > 1 } instance || windows.ContainsKey(id)) return;
        foreach (var profile in Enum.GetValues<DeviceProfile>()) AvdFiles.Delete(instance.Avd(profile));
        File.Delete(DeviceSettings.FilePath(id));
        List.Remove(id);
        List.Save();
        Changed?.Invoke();
    }

    public static void ApplyOptionsEverywhere(MainWindow from) => OptionsChanged?.Invoke(from);

    // --- AI control (Mac: AIControl): one MCP server for every instance.

    static McpHttpServer? mcp;
    /// Why the server isn't running although it's switched on (e.g. the port is taken).
    public static string? AiControlProblem { get; private set; }

    public static async Task SetAiControlAsync(bool on)
    {
        if (mcp != null) { await mcp.DisposeAsync(); mcp = null; }
        AiControlProblem = null;
        if (on)
        {
            var dispatcher = Application.Current.Dispatcher;
            var tools = new MyEmuMcp(
                instances: () => dispatcher.InvokeAsync(() => (IReadOnlyList<McpInstanceState>)List.Instances
                    .Select(i => Window(i.Id)?.McpState(i) ?? StoppedState(i)).ToList()).Task,
                start: id => dispatcher.InvokeAsync(() =>
                {
                    if (Window(id) is { } window) return window.McpStart();
                    Open(id);
                    return $"Starting {List.Find(id)?.Name}. Poll list_instances until ready is true.";
                }).Task,
                stop: id => dispatcher.InvokeAsync(() => Window(id) is { } window ? window.McpStopAsync() : Task.FromResult($"{List.Find(id)?.Name} isn't running.")).Task.Unwrap(),
                screen: id => dispatcher.Invoke(() => Window(id))?.ScreenCopy(),
                setSpeed: (id, speed) => dispatcher.InvokeAsync(() =>
                {
                    if (Window(id) is { } window) window.SetGameSpeed(speed);
                    else (DeviceSettings.Load(id) with { GameSpeed = speed }).Save(id);
                    return $"Game speed {speed}× on {List.Find(id)?.Name}. It applies to the game in front.";
                }).Task);
            try { mcp = await McpHttpServer.StartAsync(tools.Dispatcher); }
            catch (Exception e) { AiControlProblem = $"Couldn't start on port {McpHttpServer.Port}: {e.Message}"; }
        }
        Changed?.Invoke();
    }

    public static bool AiControlRunning => mcp != null;
}
