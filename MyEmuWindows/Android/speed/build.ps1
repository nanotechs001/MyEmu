# Builds gpu_tls_bridge.c into MyEmu\Assets\libgpu_tls.so (x86_64 Android), which the app ships and
# installs on the Custom model profile. Needs the Android NDK in the SDK (ndk\<version>).
$ErrorActionPreference = 'Stop'
$ndk = Get-ChildItem "$env:LOCALAPPDATA\Android\Sdk\ndk" -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $ndk) { throw 'Android NDK not found in %LOCALAPPDATA%\Android\Sdk\ndk' }
$cc = Join-Path $ndk.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin\x86_64-linux-android29-clang.cmd'
$out = Join-Path $PSScriptRoot '..\..\MyEmu\Assets\libgpu_tls.so'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
& $cc -shared -fPIC -O2 -Wall -Werror -s '-Wl,--gc-sections' -o $out (Join-Path $PSScriptRoot 'gpu_tls_bridge.c') -llog -ldl
if ($LASTEXITCODE) { throw "clang failed ($LASTEXITCODE)" }
"Built $((Resolve-Path $out).Path)"
