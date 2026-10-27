<#
Phase 0 of MyEmu for Windows: before any app code, measure whether this PC runs your games well on
Google's Android emulator engine (the one MyEmu uses).

It (1) records the machine and checks the Windows Hypervisor Platform, (2) installs Google's emulator
engine 37.2.12, adb and Android 15 with Google Play (x86-64) from Google, after you accept Google's
licenses, (3) creates a test Android, (4) boots it and checks ARM translation (your games are ARM-only),
(5) measures fps, stutters, CPU and GPU while you play. Everything goes into a report file to send back.

Run in PowerShell (not as Administrator):
    powershell -ExecutionPolicy Bypass -File .\Test-MyEmuWindows.ps1
Try the other renderer afterwards (the Mac showed it matters per game):
    powershell -ExecutionPolicy Bypass -File .\Test-MyEmuWindows.ps1 -Renderer OpenGL
#>
#Requires -Version 5.1
param(
    [ValidateSet('Vulkan', 'OpenGL')] [string]$Renderer = 'Vulkan',
    [int]$Seconds = 20
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Windows PowerShell's progress bar slows downloads a lot

$Sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$AvdHome = Join-Path $env:USERPROFILE '.android\avd'
$Repo = 'https://dl.google.com/android/repository'
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$Emulator = Join-Path $Sdk 'emulator\emulator.exe'
$Serial = 'emulator-5554'
$Report = Join-Path $PSScriptRoot ('phase0-report-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.txt')

# Pinned to the versions MyEmu is tested with on the Mac; SHA-1 values from Google's SDK index.
$Packages = @(
    @{ Name = 'adb (platform-tools 37.0.1)'; Sha1 = 'e03e78b1d80b396f1c3358e31251cb31740e1110'
       Folder = 'platform-tools'; Url = "$Repo/platform-tools_r37.0.1-win.zip" },
    @{ Name = 'Android emulator engine 37.2.12'; Sha1 = '488ed747e82de7e9bb5247becd1ac043c7e5e85d'
       Folder = 'emulator'; Url = "$Repo/emulator-windows_x64-16428233.zip" },
    @{ Name = 'Android 15 with Google Play (x86-64)'; Sha1 = '2f0054868e6aab3c098acd3decba17a82aed4176'
       Folder = 'system-images\android-35\google_apis_playstore\x86_64'
       Url = "$Repo/sys-img/google_apis_playstore/x86_64-35_r09.zip" }
)

function Say([string]$Text) {
    Write-Host $Text
    Add-Content -Path $Report -Value $Text -Encoding UTF8
}

function Fail([string]$Text) {
    Say "FAILED: $Text"
    Say "Report: $Report"
    exit 1
}

function AdbShell([string]$Command) {
    $out = & $Adb -s $Serial shell $Command 2>$null
    return ($out | Out-String).Trim()
}

# ---------------------------------------------------------------------------------------------------
Say "MyEmu Windows phase 0 - $(Get-Date -Format 'yyyy-MM-dd HH:mm') - renderer $Renderer"
Say ''
Say '=== Machine'
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Say "CPU: $($cpu.Name.Trim()) - $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads"
foreach ($gpu in Get-CimInstance Win32_VideoController) { Say "GPU: $($gpu.Name) (driver $($gpu.DriverVersion))" }
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$os = Get-CimInstance Win32_OperatingSystem
Say "RAM: $ramGb GB - $($os.Caption) build $($os.BuildNumber)"
$free = [math]::Round((Get-PSDrive -Name ($env:LOCALAPPDATA.Substring(0, 1))).Free / 1GB)
Say "Free disk on $($env:LOCALAPPDATA.Substring(0, 2)): $free GB"
Say "Hypervisor running: $((Get-CimInstance Win32_ComputerSystem).HypervisorPresent)"
if ([Environment]::Is64BitOperatingSystem -eq $false) { Fail 'needs 64-bit Windows.' }

# ---------------------------------------------------------------------------------------------------
Say ''
Say '=== Android packages'
$missing = @($Packages | Where-Object { -not (Test-Path (Join-Path $Sdk "$($_.Folder)\source.properties")) })
foreach ($p in $Packages) {
    if ($missing -notcontains $p) { Say "Already installed: $($p.Name)" }
}
if ($missing.Count -gt 0) {
    if ($free -lt 15) { Fail "needs about 15 GB free on $($env:LOCALAPPDATA.Substring(0, 2)); $free GB is free." }
    Write-Host 'Fetching Google''s license terms...'
    $work = Join-Path $env:TEMP ('myemu-phase0-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $indexes = @(
            (Join-Path $work 'repo.xml'),
            (Join-Path $work 'sysimg.xml')
        )
        & curl.exe -fsSL "$Repo/repository2-3.xml" -o $indexes[0]
        if ($LASTEXITCODE -ne 0) { Fail 'could not reach dl.google.com.' }
        & curl.exe -fsSL "$Repo/sys-img/google_apis_playstore/sys-img2-3.xml" -o $indexes[1]
        if ($LASTEXITCODE -ne 0) { Fail 'could not reach dl.google.com.' }
        # The licenses these packages use, as Google's index lists them.
        $texts = @()
        foreach ($index in $indexes) {
            [xml]$doc = Get-Content -Path $index -Raw -Encoding UTF8
            $refs = $doc.SelectNodes("//*[local-name()='remotePackage']/*[local-name()='uses-license']") |
                ForEach-Object { $_.GetAttribute('ref') } | Sort-Object -Unique
            foreach ($node in $doc.SelectNodes("//*[local-name()='license']")) {
                $id = $node.GetAttribute('id')
                if ($refs -contains $id -and $id -in @('android-sdk-license', 'android-sdk-preview-license', 'android-sdk-arm-dbt-license')) {
                    $texts += "=== $id ===`n$($node.InnerText)`n"
                }
            }
        }
        $texts | Sort-Object -Unique | Out-Host -Paging
        $answer = Read-Host 'Do you accept these Google license agreements? [y/N]'
        if ($answer -notmatch '^[Yy]') { Fail 'licenses not accepted; nothing was installed.' }
        Say 'Google licenses accepted.'

        foreach ($p in $missing) {
            Say "Downloading $($p.Name)..."
            $zip = Join-Path $work 'package.zip'
            & curl.exe -fL --progress-bar $p.Url -o $zip
            if ($LASTEXITCODE -ne 0) { Fail "$($p.Name): download failed." }
            $hash = (Get-FileHash -Path $zip -Algorithm SHA1).Hash.ToLower()
            if ($hash -ne $p.Sha1) { Fail "$($p.Name): download is damaged (checksum mismatch). Run this again." }
            Write-Host '  Unpacking...'
            $unpacked = Join-Path $work 'unpacked'
            if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
            New-Item -ItemType Directory -Path $unpacked | Out-Null
            & tar.exe -xf $zip -C $unpacked # Windows' built-in tar reads zip, much faster than Expand-Archive
            if ($LASTEXITCODE -ne 0) { Fail "$($p.Name): could not unpack." }
            Remove-Item $zip
            $top = @(Get-ChildItem -Path $unpacked) # each package unzips to one folder
            if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) { Fail "$($p.Name): unexpected package layout." }
            $target = Join-Path $Sdk $p.Folder
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            if (Test-Path $target) { Remove-Item -Recurse -Force $target } # a half-finished earlier attempt
            Move-Item -Path $top[0].FullName -Destination $target
            Say "Installed $($p.Name)"
        }
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------------
Say ''
Say '=== Hypervisor'
$accel = (& $Emulator -accel-check 2>&1 | Out-String).Trim()
Say $accel
if ($accel -notmatch 'is installed and usable|WHPX\(.*\) is installed') {
    Say 'The emulator can''t use a hypervisor. In PowerShell as Administrator run:'
    Say '    Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All'
    Say 'then restart Windows and run this script again.'
    Fail 'no usable hypervisor.'
}

# ---------------------------------------------------------------------------------------------------
Say ''
Say '=== Test Android'
$avdDir = Join-Path $AvdHome 'myemu.avd'
if (-not (Test-Path (Join-Path $AvdHome 'myemu.ini'))) {
    New-Item -ItemType Directory -Force -Path $avdDir | Out-Null
    # 6 virtual CPUs = this laptop's 6 performance cores; 8 GB of its 32.
    @"
avd.ini.encoding=UTF-8
path=$avdDir
path.rel=avd\myemu.avd
target=android-35
"@ | Set-Content -Path (Join-Path $AvdHome 'myemu.ini') -Encoding ASCII
    @'
PlayStore.enabled=yes
abi.type=x86_64
avd.ini.encoding=UTF-8
disk.dataPartition.size=16G
hw.audioInput=yes
hw.audioOutput=yes
hw.cpu.arch=x86_64
hw.cpu.ncore=6
hw.device.manufacturer=Google
hw.gltransport=asg
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.initialOrientation=landscape
hw.keyboard=yes
hw.lcd.density=240
hw.lcd.height=900
hw.lcd.width=1600
hw.ramSize=8192M
image.sysdir.1=system-images\android-35\google_apis_playstore\x86_64\
showDeviceFrame=no
tag.id=google_apis_playstore
tag.ids=google_apis_playstore
target=android-35
'@ | Set-Content -Path (Join-Path $avdDir 'config.ini') -Encoding ASCII
    Say 'Created test Android "myemu" (6 CPUs, 8 GB, 1600 x 900).'
} else {
    Say 'Using the existing test Android "myemu".'
}

$feature = if ($Renderer -eq 'Vulkan') { 'GuestAngle' } else { '-GuestAngle' }
$engineLog = Join-Path $PSScriptRoot 'phase0-engine.log'
$started = Get-Date
# Google's own window for now (MyEmu for Windows comes after this test): you play in it.
$engine = Start-Process -FilePath $Emulator -PassThru -RedirectStandardOutput $engineLog `
    -ArgumentList @('-avd', 'myemu', '-gpu', 'host', '-feature', $feature, '-no-snapshot-save', '-no-boot-anim', '-port', '5554')
& $Adb wait-for-device 2>$null
$booted = $false
for ($i = 0; $i -lt 180 -and -not $booted; $i++) {
    if ($engine.HasExited) { Fail "the engine exited during boot (see $engineLog)." }
    $booted = (AdbShell 'getprop sys.boot_completed') -eq '1'
    if (-not $booted) { Start-Sleep -Seconds 2 }
}
if (-not $booted) { Fail "Android didn't finish booting in 6 minutes (see $engineLog)." }
Say "Booted in $([math]::Round(((Get-Date) - $started).TotalSeconds)) s"
$abis = AdbShell 'getprop ro.product.cpu.abilist'
Say "Android CPU types: $abis"
Say "ARM translation: $(AdbShell 'getprop ro.dalvik.vm.native.bridge')"
if ($abis -notmatch 'arm64-v8a') {
    Say 'WARNING: this Android can''t run ARM apps; Xerion and Conquer won''t install or start.'
}
Say "Renderer: $(AdbShell 'dumpsys SurfaceFlinger | grep -m1 GLES')"
Get-Content $engineLog -ErrorAction SilentlyContinue |
    Select-String -Pattern 'Graphics Adapter|GL_RENDERER|Vulkan|ANGLE|accel' |
    Select-Object -First 8 | ForEach-Object { Say "engine: $($_.Line.Trim())" }

# ---------------------------------------------------------------------------------------------------
function Measure-Game {
    $top = AdbShell 'dumpsys activity activities | grep -m1 topResumedActivity'
    $package = if ($top -match 'u0 ([^/ ]+)/') { $Matches[1] } else { 'unknown' }
    Say ''
    Say "=== Measuring $package for $Seconds s ($Renderer)"
    $null = AdbShell 'settings put system peak_refresh_rate 120.0; settings put system min_refresh_rate 120.0'
    $null = AdbShell "cmd game set --fps 120 $package"
    $null = AdbShell 'dumpsys SurfaceFlinger --timestats -clear -enable'
    $qemu = Get-Process | Where-Object { $_.ProcessName -like 'qemu-system*' } | Select-Object -First 1
    $cpuStart = if ($qemu) { $qemu.TotalProcessorTime.TotalSeconds } else { 0 }
    $gpuSamples = @()
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    for ($s = 0; $s -lt $Seconds; $s++) {
        if ($smi) {
            $util = & nvidia-smi.exe --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null
            if ($util) { $gpuSamples += [int](($util | Select-Object -First 1).Trim()) }
        }
        Start-Sleep -Seconds 1
    }
    $stats = AdbShell 'dumpsys SurfaceFlinger --timestats -dump'
    $null = AdbShell 'dumpsys SurfaceFlinger --timestats -disable'
    # Same measure as the Mac's stress test: frames, and frames that took 25-39 ms and 40 ms or more.
    $line = ($stats -split "`n" | Select-String -Pattern 'presentToPresent histogram' -Context 0, 1 | Select-Object -First 1)
    if ($line) {
        $frames = 0; $mid = 0; $big = 0; $slow = @()
        foreach ($pair in ($line.Context.PostContext[0].Trim() -split '\s+')) {
            if ($pair -match '^(\d+)ms=(\d+)$') {
                $ms = [int]$Matches[1]; $n = [int]$Matches[2]
                $frames += $n
                if ($ms -ge 25 -and $ms -lt 40) { $mid += $n }
                if ($ms -ge 40 -and $n -gt 0) { $big += $n; $slow += $ms }
            }
        }
        Say ("fps {0:N0} | 25-39 ms: {1} | 40 ms or more: {2} [{3}]" -f ($frames / $Seconds), $mid, $big, ($slow -join ' '))
    } else {
        Say 'fps: no frame statistics (is the game drawing?)'
    }
    if ($qemu) {
        $qemu.Refresh()
        $cores = [Environment]::ProcessorCount
        $used = ($qemu.TotalProcessorTime.TotalSeconds - $cpuStart) / $Seconds * 100
        Say ("Engine CPU: {0:N0}% of one thread ({1:N0}% of all {2} threads)" -f $used, ($used / $cores), $cores)
    }
    if ($gpuSamples.Count -gt 0) {
        Say ("NVIDIA GPU busy: {0:N0}% average, {1}% peak" -f (($gpuSamples | Measure-Object -Average).Average),
            (($gpuSamples | Measure-Object -Maximum).Maximum))
    } else {
        Say 'NVIDIA GPU busy: not measured (nvidia-smi not found)'
    }
    $gamePid = AdbShell "pidof $package" # not $pid: that's PowerShell's own (read-only) process id
    if ($gamePid) {
        $threads = AdbShell "top -H -b -n 2 -d 3 -p $gamePid -o TID,%CPU"
        $busiest = ($threads -split "`n" | Where-Object { $_ -match '^\s*\d+\s+[\d.]+' } | Select-Object -Last 15 |
            Sort-Object { [double](($_.Trim() -split '\s+')[1]) } -Descending | Select-Object -First 1)
        if ($busiest) { Say "Game's busiest thread: $($busiest.Trim()) (% of one Android CPU)" }
    }
}

Say ''
Write-Host 'In the emulator window: open Play Store, sign in, install Xerion Online (and Conquer Online),'
Write-Host 'log in, set graphics to HD and go somewhere busy (a crowded town or a fight).'
Read-Host 'Then press Enter here to measure'
do {
    Measure-Game
    $again = Read-Host 'Measure again (another place or game)? [y/N]'
} while ($again -match '^[Yy]')

Say ''
Say "Done. Send this report: $Report"
Write-Host 'You can close the emulator window now.'
