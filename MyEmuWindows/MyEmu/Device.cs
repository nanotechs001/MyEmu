using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MyEmu;

/// Google's Play Store images are locked (signed, no root), so the device model can only change on the
/// root-capable google_apis image. Each instance keeps one AVD per profile, with separate Android data
/// (Mac: DeviceProfile.swift).
[JsonConverter(typeof(JsonStringEnumConverter<DeviceProfile>))]
public enum DeviceProfile { [JsonStringEnumMemberName("playStore")] PlayStore, [JsonStringEnumMemberName("customModel")] CustomModel }

public static class DeviceProfiles
{
    public static string Title(this DeviceProfile p) => p == DeviceProfile.PlayStore ? "Play Store" : "Custom model";

    public static string Avd(this Instance instance, DeviceProfile profile) =>
        profile == DeviceProfile.PlayStore ? instance.Avd : instance.Number == 1 ? "myemu-custom" : $"myemu-custom-{instance.Number}";

    /// config.ini lines that select the profile's system image (x86_64 here; the Mac's are arm64).
    public static IReadOnlyDictionary<string, string> ImageConfig(this DeviceProfile p) => p == DeviceProfile.PlayStore
        ? new Dictionary<string, string>
        {
            ["image.sysdir.1"] = @"system-images\android-35\google_apis_playstore\x86_64\", ["tag.id"] = "google_apis_playstore",
            ["tag.ids"] = "google_apis_playstore", ["tag.display"] = "Google Play", ["tag.displaynames"] = "Google Play", ["PlayStore.enabled"] = "yes",
        }
        : new Dictionary<string, string>
        {
            ["image.sysdir.1"] = @"system-images\android-35\google_apis\x86_64\", ["tag.id"] = "google_apis",
            ["tag.ids"] = "google_apis", ["tag.display"] = "Google APIs", ["tag.displaynames"] = "Google APIs", ["PlayStore.enabled"] = "no",
        };

    /// Root may write the model into Android's (otherwise read-only) property files.
    public static bool NeedsWritableSystem(this DeviceProfile p) => p == DeviceProfile.CustomModel;
}

/// What apps see as Build.BRAND / MANUFACTURER / MODEL, plus the name shown in Android's Settings.
public sealed record DeviceIdentity(
    [property: JsonPropertyName("brand")] string Brand,
    [property: JsonPropertyName("manufacturer")] string Manufacturer,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("marketName")] string MarketName)
{
    /// What Google's x86_64 emulator image reports out of the box.
    public static readonly DeviceIdentity Stock = new("google", "Google", "sdk_gphone64_x86_64", "sdk_gphone64_x86_64");
    public const int MaxLength = 40;

    /// Null when safe to write into Android, otherwise a message for the user.
    [JsonIgnore]
    public string? Problem
    {
        get
        {
            foreach (var (field, value) in new[] { ("Brand", Brand), ("Manufacturer", Manufacturer), ("Model", Model), ("Name", MarketName) })
            {
                if (string.IsNullOrWhiteSpace(value)) return $"{field} can't be empty.";
                if (value.Length > MaxLength) return $"{field} must be at most {MaxLength} characters.";
                // These values go into Android's property files through a shell script: keep them plain.
                if (!value.All(c => c < 128 && (char.IsLetterOrDigit(c) || " ._-()+".Contains(c))))
                    return $"{field} may only use letters, digits, spaces and . _ - ( ) +";
            }
            return null;
        }
    }

    /// Popular gaming phones; some games pick higher graphics settings for these.
    public static readonly DeviceIdentity[] Presets =
    [
        new("samsung", "samsung", "SM-S928B", "Galaxy S24 Ultra"),
        new("samsung", "samsung", "SM-S911B", "Galaxy S23"),
        new("samsung", "samsung", "SM-X916B", "Galaxy Tab S9 Ultra"),
        new("Xiaomi", "Xiaomi", "24030PN60G", "Xiaomi 14 Ultra"),
        new("OnePlus", "OnePlus", "CPH2581", "OnePlus 12"),
        new("asus", "asus", "ASUS_AI2401_A", "ROG Phone 8 Pro"),
        new("nubia", "nubia", "NX769J", "RedMagic 9 Pro"),
        new("google", "Google", "Pixel 8 Pro", "Pixel 8 Pro"),
    ];
}

/// The SIM's phone number on the custom-model profile; empty is the engine's default (Mac: PhoneLine.swift).
/// ponytail: the IMEI isn't settable on Windows yet — the Mac patches arm64 code in Android's radio library and
/// injects into the engine; the x86_64 image needs its own patch. The field is kept so the JSON matches.
public sealed record PhoneLine(
    [property: JsonPropertyName("phoneNumber")] string PhoneNumber = "",
    [property: JsonPropertyName("imei")] string Imei = "")
{
    /// Null when usable. The engine refuses anything but digits ("+" included) and then won't start.
    [JsonIgnore]
    public string? Problem => PhoneNumber.Length > 0 && (PhoneNumber.Length is < 3 or > 15 || !PhoneNumber.All(char.IsAsciiDigit))
        ? "Phone number: 3–15 digits, no + or spaces (country code first, e.g. 15550101234)." : null;
}

/// An instance's device settings: profile, model and phone line (the Mac keeps them in UserDefaults per
/// instance). %LOCALAPPDATA%\MyEmu\device\<instance id>.json.
public sealed record DeviceSettings(
    [property: JsonPropertyName("profile")] DeviceProfile Profile,
    [property: JsonPropertyName("identity")] DeviceIdentity Identity,
    [property: JsonPropertyName("phoneLine")] PhoneLine PhoneLine)
{
    public static readonly DeviceSettings Default = new(DeviceProfile.PlayStore, DeviceIdentity.Stock, new PhoneLine());

    public static string Folder { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MyEmu", "device");
    public static string FilePath(string instanceId) => Path.Combine(Folder, $"{instanceId}.json");

    public static DeviceSettings Load(string instanceId)
    {
        try { return JsonSerializer.Deserialize<DeviceSettings>(File.ReadAllText(FilePath(instanceId))) ?? Default; }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return Default; }
    }

    public void Save(string instanceId)
    {
        Directory.CreateDirectory(Folder);
        File.WriteAllText(FilePath(instanceId), JsonSerializer.Serialize(this));
    }
}

/// The custom-model profile's Android changes, over adb as root (Mac: Engine+Device.swift).
public static class DeviceSetup
{
    const string BootWait = "while [ \"$(getprop sys.boot_completed)\" != 1 ]; do sleep 1; done";

    /// Android property files that each carry a `ro.product.<partition>.*` copy of the identity.
    static readonly string[] BuildPropFiles = ["/system/build.prop", "/system_ext/etc/build.prop", "/vendor/build.prop",
        "/product/etc/build.prop", "/odm/etc/build.prop", "/vendor/odm/etc/build.prop"];

    /// Shell script (root, remounted system) that writes `identity` into every property file, starting from a
    /// one-time backup so repeated changes don't pile up. `identity` must have no Problem.
    public static string IdentityScript(DeviceIdentity identity) => string.Join("; ", BuildPropFiles.Select(file =>
    {
        var steps = $"if [ -f {file} ]; then [ -f {file}.myemu-orig ] || cp -p {file} {file}.myemu-orig; cp -p {file}.myemu-orig {file}";
        if (identity != DeviceIdentity.Stock)
            steps += " && sed -i -E"
                + $" -e \"s/^(ro\\.product\\.[a-z_]+\\.brand)=.*/\\1={identity.Brand}/\""
                + $" -e \"s/^(ro\\.product\\.[a-z_]+\\.manufacturer)=.*/\\1={identity.Manufacturer}/\""
                + $" -e \"s/^(ro\\.product\\.[a-z_]+\\.model)=.*/\\1={identity.Model}/\" {file}";
        return steps + " || exit 1; fi";
    }));

    /// Makes Android report `identity`. True when it changed something (Android has then rebooted once).
    public static async Task<bool> ApplyIdentityAsync(DeviceIdentity identity, string serial)
    {
        var current = (await Engine.AdbAsync(serial, ["wait-for-device", "shell",
            $"{BootWait}; getprop ro.product.brand; getprop ro.product.manufacturer; getprop ro.product.model"]))
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (current.SequenceEqual([identity.Brand, identity.Manufacturer, identity.Model])) return false;
        await RemountAsync(serial);
        await Engine.AdbAsync(serial, ["shell", IdentityScript(identity)]);
        await RebootAsync(serial);
        return true;
    }

    /// The phone name in Android's Settings. `name` must be a validated MarketName.
    public static Task SetDeviceNameAsync(string name, string serial) =>
        Engine.AdbAsync(serial, ["wait-for-device", "shell", $"{BootWait}; settings put global device_name \"{name}\""]);

    // --- Google Play Store on the custom-model image

    /// Google's built-in apps as the Play Store image has them. They only work as a set (Play services and
    /// Play Store must share Google's original key); the custom image's own pair is signed differently.
    public static readonly string[] PlayGoogleApps =
    [
        "/product/priv-app/Phonesky/Phonesky.apk",
        "/product/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk",
        "/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
    ];
    /// Google's placeholder under Play Store's package name: with both built in, Play Store's self-update
    /// can land on it and crash ("Google Play Store keeps stopping").
    const string LicenseCheckerDir = "/product/app/LicenseChecker";
    const string PlayAppsOnData = "/data/myemu-play";
    static string PlayAppsFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MyEmu", "playstore");
    static string LocalCopy(string path) => Path.Combine(PlayAppsFolder, Path.GetFileName(path));
    /// adb console port for the one-off copy, clear of the instances' 5554, 5556, …
    const int ExtractionPort = 5680;

    /// Prints "ready" when each Google app is the Play Store image's (same SHA-256) and the placeholder is gone.
    public static string PlayAppsReadyCheck(IReadOnlyList<string> hashes) =>
        string.Join(" && ", PlayGoogleApps.Zip(hashes, (path, hash) => $"sha256sum {path} 2>/dev/null | grep -q ^{hash}"))
        + $" && test ! -e {LicenseCheckerDir} && echo ready";

    /// Makes a custom-model Android's Google apps the Play Store image's. True when it changed them
    /// (Android has then rebooted once).
    public static async Task<bool> EnsurePlayStoreAsync(string serial, string playStoreAvd)
    {
        if (!PlayGoogleApps.All(p => File.Exists(LocalCopy(p)))) await CopyPlayAppsAsync(playStoreAvd);
        var hashes = PlayGoogleApps.Select(p => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(LocalCopy(p)))).ToLowerInvariant()).ToList();
        if ((await Engine.AdbAsync(serial, ["wait-for-device", "shell", $"{BootWait}; {PlayAppsReadyCheck(hashes)} || true"])).Contains("ready"))
            return false;
        await RemountAsync(serial);
        // An update of the image's own Play services in /data is signed with the other key; drop it.
        await Engine.AdbAsync(serial, ["shell", "cmd package uninstall-system-updates com.google.android.gms || true"]);
        // The x86_64 image's writable-system overlay is only ~80 MB (its spare super space) and the apps are
        // ~320 MB, so they live in /data, labelled like installed apps, and the system paths are symlinks.
        // Android still scans them as privileged system apps (checked: PRIVILEGED PRODUCT, Play Store opens).
        await Engine.AdbAsync(serial, ["shell", $"mkdir -p {PlayAppsOnData} && chmod 755 {PlayAppsOnData}"]);
        foreach (var path in PlayGoogleApps)
        {
            var dir = path[..path.LastIndexOf('/')];
            var stored = $"{PlayAppsOnData}/{path[(path.LastIndexOf('/') + 1)..]}";
            await Engine.AdbAsync(serial, ["push", LocalCopy(path), stored]);
            // The precompiled code next to the APK belongs to the old one; Android recompiles.
            await Engine.AdbAsync(serial, ["shell", $"chmod 644 {stored} && chcon u:object_r:apk_data_file:s0 {PlayAppsOnData} {stored}"
                + $" && mkdir -p {dir} && chmod 755 {dir} && rm -rf {dir}/oat {path} && ln -s {stored} {path}"]);
        }
        await Engine.AdbAsync(serial, ["shell", $"rm -rf {LicenseCheckerDir}"]);
        await RebootAsync(serial);
        return true;
    }

    /// Boots the Play Store AVD read-only (nothing it does is kept) just long enough to copy its Google apps out.
    static async Task CopyPlayAppsAsync(string avd)
    {
        var info = new System.Diagnostics.ProcessStartInfo(Engine.EmulatorExe) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in new[] { "-avd", avd, "-read-only", "-no-window", "-gpu", "host", "-no-snapshot", "-no-boot-anim", "-port", ExtractionPort.ToString() })
            info.ArgumentList.Add(arg);
        using var process = System.Diagnostics.Process.Start(info)!;
        var serial = $"emulator-{ExtractionPort}";
        try
        {
            var booted = false;
            for (var i = 0; i < 180 && !booted; i++)
            {
                if (process.HasExited) throw new InvalidOperationException($"The Play Store Android stopped while starting (code {process.ExitCode}).");
                try { booted = (await Engine.AdbAsync(serial, ["shell", "getprop sys.boot_completed"])).Contains('1'); } catch { }
                if (!booted) await Task.Delay(1000);
            }
            if (!booted) throw new TimeoutException("The Play Store Android didn't finish starting.");
            Directory.CreateDirectory(PlayAppsFolder);
            foreach (var path in PlayGoogleApps)
            {
                var copy = LocalCopy(path);
                var partial = copy + ".partial"; // never leave half a file as the real one
                File.Delete(partial);
                await Engine.AdbAsync(serial, ["pull", path, partial]);
                File.Move(partial, copy, overwrite: true);
            }
        }
        finally
        {
            try { await Engine.AdbAsync(serial, ["emu", "kill"]); } catch { }
            if (!process.WaitForExit(10_000)) process.Kill(entireProcessTree: true);
        }
    }

    // --- root

    /// Root, and system partitions writable (custom-model profile only).
    static async Task RemountAsync(string serial)
    {
        await BecomeRootAsync(serial);
        if ((await Engine.AdbAsync(serial, ["remount"])).Contains("reboot"))
        {
            // First time only: the writable overlay exists after one reboot.
            await RebootAsync(serial);
            await BecomeRootAsync(serial);
            await Engine.AdbAsync(serial, ["remount"]);
        }
    }

    static async Task BecomeRootAsync(string serial)
    {
        await Engine.AdbAsync(serial, ["root"]);
        for (var i = 0; i < 20; i++) // adbd restarts as root; wait until it's back
        {
            try { if ((await Engine.AdbAsync(serial, ["wait-for-device", "shell", "id -u"])).Trim() == "0") return; } catch { }
            await Task.Delay(1000);
        }
        throw new InvalidOperationException("Couldn't get root in Android.");
    }

    static async Task RebootAsync(string serial)
    {
        await Engine.AdbAsync(serial, ["reboot"]);
        await Task.Delay(6000); // Android takes a moment to go down; checking sooner sees the old boot
        await Engine.AdbAsync(serial, ["wait-for-device", "shell", BootWait]);
    }
}
