using System.Windows;

namespace MyEmu;

public static class App
{
    /// `MyEmu.exe [avd]` — the Android to run (default "myemu", the one phase 0 made).
    [STAThread]
    public static void Main(string[] args) =>
        new Application { ShutdownMode = ShutdownMode.OnMainWindowClose }.Run(new MainWindow(args.FirstOrDefault() ?? "myemu"));
}
