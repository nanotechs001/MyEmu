; MyEmu for Windows: offline installer. Build with build.ps1 (it publishes the app and passes the SDK path).
; Installs per user (no admin) with Google's emulator, adb and both Android 15 images in {app}\sdk,
; where the app looks first (Engine.Sdk). Androids themselves live in %USERPROFILE%\.android\avd and
; MyEmu's settings in %LOCALAPPDATA%\MyEmu; uninstalling keeps both.

#ifndef Sdk
  #define Sdk GetEnv("LOCALAPPDATA") + "\Android\Sdk"
#endif
#ifndef Version
  #define Version "0.1.0"
#endif
#ifndef DiskSpanning
  #define DiskSpanning "no"
#endif
#define Images Sdk + "\system-images\android-35"

[Setup]
AppId={{6F3B0C1E-4C7A-4D3B-9B1E-2A6E8C7D5F10}
AppName=MyEmu
AppVersion={#Version}
AppVerName=MyEmu {#Version}
AppPublisher=MyEmu
DefaultDirName={autopf}\MyEmu
DefaultGroupName=MyEmu
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 2004: the first with Windows Hypervisor Platform as the emulator needs it
MinVersion=10.0.19041
LicenseFile=license.txt
SetupIconFile=..\MyEmu\Assets\AppIcon.ico
UninstallDisplayIcon={app}\MyEmu.exe
WizardStyle=modern
OutputDir=output
OutputBaseFilename=MyEmu-Setup-{#Version}
; Gigabytes of disk images: fast LZMA2 on several threads, each file on its own (not solid).
Compression=lzma2/fast
LZMANumBlockThreads=8
LZMAUseSeparateProcess=yes
SolidCompression=no
; One exe holds up to ~4 GB; build.ps1 -DiskSpanning puts the data in a separate .bin if it's bigger.
DiskSpanning={#DiskSpanning}
DiskSliceSize=max
CloseApplications=yes

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"

[Files]
Source: "publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "{#Sdk}\emulator\*"; DestDir: "{app}\sdk\emulator"; Flags: ignoreversion recursesubdirs
Source: "{#Sdk}\platform-tools\*"; DestDir: "{app}\sdk\platform-tools"; Flags: ignoreversion recursesubdirs
Source: "{#Images}\google_apis_playstore\x86_64\*"; DestDir: "{app}\sdk\system-images\android-35\google_apis_playstore\x86_64"; Flags: ignoreversion recursesubdirs
Source: "{#Images}\google_apis\x86_64\*"; DestDir: "{app}\sdk\system-images\android-35\google_apis\x86_64"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{autoprograms}\MyEmu"; Filename: "{app}\MyEmu.exe"
Name: "{autodesktop}\MyEmu"; Filename: "{app}\MyEmu.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\MyEmu.exe"; Description: "Start MyEmu"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; adb's server runs from {app}\sdk and would keep its files in use
Filename: "{app}\sdk\platform-tools\adb.exe"; Parameters: "kill-server"; Flags: runhidden; RunOnceId: "AdbKillServer"

[Code]
var
  RestartForHypervisor: Boolean;

// Windows Hypervisor Platform: InstallState 1 = on. Readable without admin.
function HypervisorPlatformOn(): Boolean;
var
  Code: Integer;
begin
  Result := Exec('powershell.exe',
    '-NoProfile -Command "if ((Get-CimInstance Win32_OptionalFeature | Where-Object Name -eq HypervisorPlatform).InstallState -eq 1) { exit 0 } else { exit 1 }"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

// Runs PowerShell over the processes started from `Folder` ($p) and returns its exit code.
function WithProcessesIn(Folder, Script: String): Integer;
begin
  if not Exec('powershell.exe', '-NoProfile -Command "$d = ''' + Folder + '''; ' +
      '$p = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($d, ''OrdinalIgnoreCase'') }); ' +
      Script + '"', '', SW_HIDE, ewWaitUntilTerminated, Result) then
    Result := -1;
end;

// Android keeps running for a few seconds after MyEmu's window closes, holding files in {app}\sdk:
// give it 20 s to shut down, then stop what's left (adb's server included).
procedure StopEngine();
begin
  WithProcessesIn(ExpandConstant('{app}\sdk'),
    '$end = (Get-Date).AddSeconds(20); while ($p.Count -and (Get-Date) -lt $end) { Start-Sleep 1; ' +
    '$p = @($p | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }) }; ' +
    '$p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }');
end;

function MyEmuRunning(): Boolean;
begin
  Result := WithProcessesIn(ExpandConstant('{app}\MyEmu.exe'), 'exit [int]($p.Count -gt 0)') = 1;
end;

// An upgrade: Restart Manager closes MyEmu (CloseApplications); its engine and adb then hold {app}\sdk.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopEngine();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  Result := not MyEmuRunning();
  if not Result then
    SuppressibleMsgBox('Close MyEmu first (its Androids stop with it), then uninstall again.', mbError, MB_OK, IDOK)
  else
    StopEngine();
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if (CurStep <> ssPostInstall) or HypervisorPlatformOn() then Exit;
  if SuppressibleMsgBox('MyEmu runs Android with Windows Hypervisor Platform, which is off on this PC.' + #13#10#13#10 +
      'Turn it on now? Windows asks for administrator permission, then needs a restart.',
      mbConfirmation, MB_YESNO, IDYES) <> IDYES then
  begin
    SuppressibleMsgBox('MyEmu can''t start Android until Windows Hypervisor Platform is on: turn on ' +
      '"Windows Hypervisor Platform" in Windows Features, then restart.', mbInformation, MB_OK, IDOK);
    Exit;
  end;
  // The feature counts as on only after the restart, so the elevated run finishing is the check.
  if ShellExec('runas', 'powershell.exe',
      '-NoProfile -Command "Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart"',
      '', SW_HIDE, ewWaitUntilTerminated, Code) then
    RestartForHypervisor := True
  else
    SuppressibleMsgBox('Windows Hypervisor Platform wasn''t turned on. Turn it on in Windows Features, then restart.',
      mbError, MB_OK, IDOK);
end;

function NeedRestart(): Boolean;
begin
  Result := RestartForHypervisor;
end;
