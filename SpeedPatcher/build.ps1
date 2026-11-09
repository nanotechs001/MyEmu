# Builds build\XerionSpeedPatcher.apk: the speed button (overlay\ -> dex), the speed library that
# carries it (native\ -> libjnigraphicz.so for arm64-v8a and armeabi-v7a) and the patcher app (app\),
# which puts that library into a copy of Xerion and signs it with keys\ (made once, never committed:
# keep it, or patched Xerions can't be updated in place).
# Needs: the Android SDK (build-tools, a platform, the NDK), a JDK, and openssl (comes with Git).
$ErrorActionPreference = 'Stop'
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$latest = { param($dir) Get-ChildItem $dir -Directory | Sort-Object { [version]($_.Name -replace '[^\d.]', '') } | Select-Object -Last 1 }
$bt = (& $latest "$sdk\build-tools").FullName
$jar = Join-Path (& $latest "$sdk\platforms").FullName 'android.jar'
$llvm = Join-Path (& $latest "$sdk\ndk").FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin'
$apksig = "$bt\lib\apksigner.jar"
$root = $PSScriptRoot
$b = "$root\build"
function Run { param($exe) & $exe @args; if ($LASTEXITCODE) { throw "$(Split-Path $exe -Leaf) failed ($LASTEXITCODE)" } }

Remove-Item -Recurse -Force $b -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$b\assets", "$root\keys" | Out-Null

# Signing key, made once.
if (-not (Test-Path "$root\keys\key.pk8")) {
    $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
    if (-not $openssl) { $openssl = "$env:ProgramFiles\Git\usr\bin\openssl.exe" }
    Run $openssl req -x509 -newkey rsa:2048 -nodes -keyout "$b\key.pem" -out "$b\cert.pem" -days 10000 -subj '/CN=MyEmu Xerion Speed'
    Run $openssl pkcs8 -topk8 -nocrypt -in "$b\key.pem" -outform DER -out "$root\keys\key.pk8"
    Run $openssl x509 -in "$b\cert.pem" -outform DER -out "$root\keys\cert.der"
    Remove-Item "$b\key.pem", "$b\cert.pem"
}
Copy-Item "$root\keys\key.pk8", "$root\keys\cert.der" "$b\assets"

# Speed button -> dex -> C header.
Run javac --release 11 -nowarn -cp $jar -d "$b\overlay" "$root\overlay\SpeedOverlay.java"
Run "$bt\d8.bat" --release --min-api 26 --lib $jar --output "$b\overlay" (Get-ChildItem "$b\overlay" -Recurse -Filter *.class).FullName
$dex = [IO.File]::ReadAllBytes("$b\overlay\classes.dex")
$hex = ($dex | ForEach-Object { '0x{0:x2}' -f $_ }) -join ','
Set-Content -Encoding ascii "$b\overlay_dex.h" "static const unsigned char overlay_dex[] = {$hex};"

# Speed library, per ABI Xerion ships.
foreach ($abi in @{ 'arm64-v8a' = 'aarch64-linux-android21'; 'armeabi-v7a' = 'armv7a-linux-androideabi21' }.GetEnumerator()) {
    $out = "$b\assets\speed-$($abi.Key).so" # flat: aapt2 on Windows stores folders with \ in asset names
    Run "$llvm\$($abi.Value)-clang.cmd" -shared -fPIC -O2 -Wall -Werror -s "-I$b" '-Wl,--gc-sections' '-Wl,-soname,libjnigraphicz.so' `
        -o $out "$root\native\xerion_speed.c" '-Wl,--no-as-needed' -ljnigraphics -llog -ldl
}

# Patcher app.
Run "$bt\aapt2.exe" link -o "$b\app.apk" --manifest "$root\app\AndroidManifest.xml" -I $jar -A "$b\assets" `
    --min-sdk-version 26 --target-sdk-version 34 --version-code 1 --version-name 0.1
Run javac --release 11 -nowarn -cp "$jar;$apksig" -d "$b\app" (Get-ChildItem "$root\app\src" -Recurse -Filter *.java).FullName
Run "$bt\d8.bat" --release --min-api 26 --lib $jar --output "$b\app" (Get-ChildItem "$b\app" -Recurse -Filter *.class).FullName $apksig
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open("$b\app.apk", 'Update')
[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$b\app\classes.dex", 'classes.dex')
$zip.Dispose()
Run "$bt\zipalign.exe" -p -f 4 "$b\app.apk" "$b\app-aligned.apk"
Run "$bt\apksigner.bat" sign --key "$root\keys\key.pk8" --cert "$root\keys\cert.der" --out "$b\XerionSpeedPatcher.apk" "$b\app-aligned.apk"
"Built $b\XerionSpeedPatcher.apk"
