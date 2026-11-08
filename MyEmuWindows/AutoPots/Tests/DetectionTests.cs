// Ports of the Mac app's AutoPotsDetectionTests.swift (themselves autopotsCO's HpDetectorTest and SimpleHpTest):
// same screenshots, same expected ranges.
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MyEmu.AutoPots;
using Xunit;

namespace MyEmu.AutoPots.Tests;

/// Pixels in an array (decoded screenshots and synthetic frames).
sealed record ArrayFrame(int Width, int Height, int[] Px) : IPixelFrame
{
    public int Rgb(int x, int y) => Px[y * Width + x];

    public static ArrayFrame Load(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "autopots", name);
        var decoder = BitmapDecoder.Create(new Uri(path), BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
        var bitmap = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgr32, null, 0);
        int w = bitmap.PixelWidth, h = bitmap.PixelHeight;
        var bytes = new byte[w * h * 4];
        bitmap.CopyPixels(bytes, w * 4, 0);
        var px = new int[w * h];
        for (int i = 0; i < px.Length; i++) px[i] = bytes[i * 4 + 2] << 16 | bytes[i * 4 + 1] << 8 | bytes[i * 4];
        return new ArrayFrame(w, h, px);
    }

    /// 2×2-averaged half-scale view (the downscaled capture AutoPots reads).
    public ArrayFrame Half()
    {
        int w = Width / 2, h = Height / 2;
        var px = new int[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int r = 0, g = 0, b = 0;
                for (int dy = 0; dy <= 1; dy++)
                    for (int dx = 0; dx <= 1; dx++)
                    {
                        int c = Rgb(x * 2 + dx, y * 2 + dy);
                        r += (c >> 16) & 0xFF; g += (c >> 8) & 0xFF; b += c & 0xFF;
                    }
                px[y * w + x] = (r / 4) << 16 | (g / 4) << 8 | (b / 4);
            }
        return new ArrayFrame(w, h, px);
    }

    /// Red and blue swapped (a BGRA capture read as RGBA).
    public ArrayFrame Swapped() =>
        new(Width, Height, Px.Select(c => (c & 0xFF) << 16 | (c & 0xFF00) | ((c >> 16) & 0xFF)).ToArray());
}

public class DetectionTests
{
    public static readonly TheoryData<string> OrbShots = new() { "full_exp.png", "full_no_exp.png", "reduced_exp.png", "reduced_no_exp.png" };

    static bool In(float v, float lo, float hi) => v >= lo && v <= hi;

    [Fact]
    public void OrbDefaultBoxSeparatesFullFromReducedHP()
    {
        // The default box: centre (609, 645), 44×92.
        float Hp(string name) => HpDetector.HpFractionArc(ArrayFrame.Load(name), 609 - 22, 645 - 46, 44, 92);
        var fulls = new[] { Hp("full_no_exp.png"), Hp("full_exp.png") };
        var reduced = new[] { Hp("reduced_no_exp.png"), Hp("reduced_exp.png") };
        foreach (var f in fulls) Assert.True(f >= 0.90f, $"full HP read {f}");
        foreach (var r in reduced) Assert.True(r < 0.90f, $"reduced HP read {r}");
        Assert.True(fulls.Min() - reduced.Max() > 0.05f);
    }

    [Theory, MemberData(nameof(OrbShots))]
    public void AutoMapFindsTheOrbAndItsPotion(string name)
    {
        var frame = ArrayFrame.Load(name);
        var box = HpDetector.AutoMapOrb(frame);
        Assert.True(box != null, $"{name}: orb must be found");
        // Measured red half x588…631, y599…691; the top must be at or above 599.
        Assert.True(In(box![0], 583, 593), $"left {box[0]}");
        Assert.True(In(box[1], 580, 599), $"top {box[1]}");
        Assert.True(In(box[2], 38, 50), $"width {box[2]}");
        Assert.True(In(box[1] + box[3], 688, 702), $"bottom {box[1] + box[3]}");
        float f = HpDetector.HpFractionArc(frame, box[0], box[1], box[2], box[3]);
        if (name.StartsWith("full")) Assert.True(f >= 0.95f, $"full read {f}"); else Assert.True(f < 0.90f, $"reduced read {f}");
        // The derived potion point lands on the bottle (x542…565, y625…683).
        float px = box[0] + HpDetector.PotionXPerWidth * box[2];
        float py = box[1] + HpDetector.PotionYPerHeight * box[3];
        Assert.True(In(px, 542, 566) && In(py, 630, 685), $"potion ({px}, {py})");
    }

    [Fact]
    public void AutoMapFindsNoOrbInSimpleView()
    {
        Assert.Null(HpDetector.AutoMapOrb(ArrayFrame.Load("simple_view.png")));
        // Its red-brown temple woodwork forms a plausible red run; only the blue-half check rejects it.
        Assert.Null(HpDetector.AutoMapOrb(ArrayFrame.Load("simple_poco.jpg")));
    }

    [Fact]
    public void AutoMapFindsTheOrbOnAWideScreenAndAtHalfScale()
    {
        var wide = ArrayFrame.Load("poco_wide.jpg"); // 20:9
        var box = HpDetector.AutoMapOrb(wide);
        Assert.NotNull(box);
        Assert.True(In(box![0], 1113, 1133) && In(box[2], 55, 75), $"box {string.Join(",", box)}");
        Assert.True(HpDetector.HpFractionArc(wide, box[0], box[1], box[2], box[3]) >= 0.9f);

        var half = wide.Half();
        var halfBox = HpDetector.AutoMapOrb(half);
        Assert.True(halfBox != null, "orb at half scale");
        Assert.True(In(halfBox![0], 555, 567) && In(halfBox[2], 27, 38), $"half box {string.Join(",", halfBox)}");
        Assert.True(HpDetector.HpFractionArc(half, halfBox[0], halfBox[1], halfBox[2], halfBox[3]) >= 0.97f);
        Assert.Null(HpDetector.AutoMapOrb(ArrayFrame.Load("simple_poco.jpg").Half()));
    }

    /// The fast path reads HP on every capture, so it has to stay far below a frame's time.
    [Fact]
    public void PerFrameHPReadIsFarUnderAFrame()
    {
        var frame = ArrayFrame.Load("reduced_exp.png");
        var settings = new AutoPotsSettings { OrbBox = new PixelRect(587, 599, 44, 92), OrbPotion = new PixelPoint(553, 668) };
        const int runs = 2000;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        float? value = null;
        for (int i = 0; i < runs; i++) value = Runner.Read(frame, settings);
        double perReadMs = clock.Elapsed.TotalMilliseconds / runs;
        Assert.True(value < AutoPotsRules.TriggerLevel, $"reduced HP must be detected, read {value}");
        Assert.True(perReadMs < 1, $"{perReadMs} ms per read; a 165 Hz frame is 6 ms");
    }

    [Fact]
    public void SwappedColorChannelsFindNoOrb()
    {
        var frame = ArrayFrame.Load("poco_wide.jpg");
        Assert.Null(HpDetector.AutoMapOrb(frame.Swapped()));
        Assert.NotNull(HpDetector.AutoMapOrb(frame.Swapped().Swapped()));
    }

    [Fact]
    public void HpRednessRejectsAMisplacedBox()
    {
        foreach (var name in new[] { "full_exp.png", "full_no_exp.png", "poco_wide.jpg" })
        {
            var img = ArrayFrame.Load(name);
            var b = HpDetector.AutoMapOrb(img)!;
            Assert.True(HpDetector.HpRedFraction(img, b[0], b[1], b[2], b[3]) >= 0.6f, $"{name} on the orb");
            Assert.True(HpDetector.HpRedFraction(img, b[0] + (int)(1.4f * b[2]), b[1], b[2], b[3]) < 0.3f, $"{name} on blue");
            Assert.True(HpDetector.HpRedFraction(img, b[0], b[1] - b[3], b[2], b[3]) < 0.3f, $"{name} above");
            Assert.True(HpDetector.HpRedFraction(img, b[0] - (int)(1.2f * b[2]), b[1], b[2], b[3]) < 0.3f, $"{name} on potion");
        }
    }

    [Fact]
    public void DrainedPixelClassification()
    {
        Assert.True(HpDetector.IsEmpty(0x202020));   // dark neutral: drained
        Assert.True(HpDetector.IsEmpty(0x686A6B));   // mid grey: drained
        Assert.False(HpDetector.IsEmpty(0xC83020));  // bright red: HP
        Assert.False(HpDetector.IsEmpty(0x802C2C));  // dark red: HP
        Assert.False(HpDetector.IsEmpty(0xFFF9D9));  // highlight
    }

    [Fact]
    public void SimpleViewAutoMapFindsDigitsAndPotion()
    {
        var res = SimpleHp.AutoMap(ArrayFrame.Load("simple_view.png"));
        Assert.False(res.FromFallback);
        Assert.True(In(res.Left, 85, 95) && In(res.Top, 3, 9) && In(res.Height, 12, 20), $"box {res}");
        Assert.True(res.Left + res.Width >= 139, "box must cover the % ending at 139");
        Assert.True(In(res.PotionX, 125, 155) && In(res.PotionY, 65, 100), $"potion {res}");

        var wide = SimpleHp.AutoMap(ArrayFrame.Load("simple_poco.jpg"));
        Assert.False(wide.FromFallback);
        Assert.True(In(wide.Left, 132, 145) && In(wide.Top, 5, 12) && In(wide.Height, 18, 28), $"box {wide}");
        Assert.True(In(wide.PotionX, 50, 85) && In(wide.PotionY, 105, 145), $"potion {wide}");
        Assert.True(wide.PotionFound);
    }

    [Fact]
    public void SimpleViewTemplateMatchesFullHPAndBreaksOnChange()
    {
        var frame = ArrayFrame.Load("simple_view.png");
        var res = SimpleHp.AutoMap(frame);
        var sig = SimpleHp.BuildSignature(frame, res.Left, res.Top, res.Width, res.Height, scale: 1);
        Assert.NotNull(sig);
        float Match(IPixelFrame f, int dx = 0) =>
            SimpleHp.Match(f, res.Left + dx, res.Top, res.Width, res.Height, 1, sig!, res.Width, res.Height);
        Assert.True(Match(frame) >= 0.99f);
        Assert.True(Match(frame, dx: 8) < 0.90f); // different glyphs under the box
        // A dimmer scene still reads full HP; the template adapts to brightness.
        foreach (var factor in new[] { 0.85, 0.7 })
        {
            var dim = new ArrayFrame(frame.Width, frame.Height, frame.Px.Select(c =>
                (int)(((c >> 16) & 0xFF) * factor) << 16 | (int)(((c >> 8) & 0xFF) * factor) << 8 | (int)((c & 0xFF) * factor)).ToArray());
            Assert.True(Match(dim) >= 0.97f, $"full HP at brightness ×{factor}");
        }
        // No text in the box at all: unreadable (0).
        Assert.Equal(0, SimpleHp.Match(frame, 150, res.Top, res.Width, res.Height, 1, sig!, res.Width, res.Height));
        Assert.Equal(sig, SimpleHp.Decode(SimpleHp.Encode(sig!)));
        Assert.Null(SimpleHp.Decode("0101")); // pre-adaptive strings recalibrate
    }
}

public class NoManaOrbTests
{
    /// MyEmu on Windows, 1600×900: a class without mana, whose orb is red on both sides of the divider.
    [Fact]
    public void AutoDetectFindsAnAllRedOrbAndReadsADrain()
    {
        var frame = ArrayFrame.Load("no_mana_full.png");
        var (change, message) = Calibration.Detect(() => frame, GameView.Orb);
        Assert.True(change != null, message);
        var s = change!(new AutoPotsSettings());
        var box = s.OrbBox!;
        // Measured red half x732…789, y745…873; the red potion bottle is at about (685, 835).
        Assert.InRange(box.X, 728, 738);
        Assert.InRange(box.Width, 50, 62);
        Assert.InRange(s.OrbPotion!.X, 672, 698);
        Assert.InRange(s.OrbPotion!.Y, 818, 850);
        // HP drained from the top: darken the top 40% of the orb.
        var px = frame.Px.ToArray();
        for (int y = 745; y < 745 + 51; y++) for (int x = 700; x < 870; x++) px[y * frame.Width + x] = 0x101010;
        Assert.True(HpDetector.HpFractionArc(frame with { Px = px }, box.X, box.Y, box.Width, box.Height) < 0.7f);
    }
}
