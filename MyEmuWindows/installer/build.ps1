# Builds the offline installer: publishes MyEmu self-contained (no .NET needed on the PC), then
# compiles MyEmu.iss with Inno Setup 6+ into output\MyEmu-Setup-<version>.exe.
# The SDK parts (emulator, platform-tools, both Android 15 x86_64 images) come from -Sdk, by default
# Android Studio's SDK where phase 0 and the Custom model download put them.
param(
    [string]$Version = '0.1.0',
    [string]$Sdk = "$env:LOCALAPPDATA\Android\Sdk",
    # Setup data in a separate .bin next to the exe; needed if it compresses past ~4 GB.
    [switch]$DiskSpanning
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
foreach ($part in 'emulator\emulator.exe', 'platform-tools\adb.exe',
        'system-images\android-35\google_apis_playstore\x86_64\system.img',
        'system-images\android-35\google_apis\x86_64\system.img') {
    if (-not (Test-Path (Join-Path $Sdk $part))) { throw "Missing $part in $Sdk" }
}
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found' }

$publish = Join-Path $here 'publish'
if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
dotnet publish (Join-Path $here '..\MyEmu\MyEmu.csproj') -c Release -r win-x64 --self-contained -o $publish -p:Version=$Version
if ($LASTEXITCODE) { throw "dotnet publish failed ($LASTEXITCODE)" }

& $iscc "/DSdk=$Sdk" "/DVersion=$Version" "/DDiskSpanning=$(if ($DiskSpanning) { 'yes' } else { 'no' })" (Join-Path $here 'MyEmu.iss')
if ($LASTEXITCODE) { throw "ISCC failed ($LASTEXITCODE)" }
Get-ChildItem (Join-Path $here 'output') | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB) } }
