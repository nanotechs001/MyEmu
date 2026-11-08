// AutoPots' Auto-detect (the Mac app's calibration step 0, autopotsCO's), shared by the MuMu app and MyEmu.
namespace MyEmu.AutoPots;

public static class Calibration
{
    const int DetectSamples = 3, DetectTries = 5, DetectGapMs = 200;
    /// A box that reads below this at full HP has its top lowered until it doesn't (up to 40 px).
    const float FullHpGate = 0.97f;
    const int MaxNudgePx = 40;
    /// autopotsCO aims the orb potion 8 px below the computed point.
    const int OrbPotionBiasPx = 8;

    /// Finds the HP orb or text and the potion on screen (HP must be full). `captureCopy` returns a
    /// stable copy of the current screen. Returns the settings change (null when nothing was found).
    public static (Func<AutoPotsSettings, AutoPotsSettings>? Change, string Message) Detect(Func<IPixelFrame?> captureCopy, GameView view)
    {
        var orbBoxes = new List<int[]>();
        var simpleMaps = new List<SimpleHp.MapResult>();
        IPixelFrame? last = null;
        for (int attempt = 0; attempt < DetectTries; attempt++)
        {
            if (attempt > 0) Thread.Sleep(DetectGapMs);
            if (captureCopy() is not { } frame) continue;
            last = frame;
            if (view == GameView.Orb) { if (HpDetector.AutoMapOrb(frame) is { } box) orbBoxes.Add(box); }
            else if (SimpleHp.AutoMap(frame) is { FromFallback: false } map) simpleMaps.Add(map);
            if (Math.Max(orbBoxes.Count, simpleMaps.Count) >= DetectSamples) break;
        }
        if (last == null) return (null, "Couldn't read the screen. Is Android running?");
        return view == GameView.Orb ? DetectOrb(orbBoxes, last) : DetectSimple(simpleMaps, last);
    }

    static (Func<AutoPotsSettings, AutoPotsSettings>?, string) DetectOrb(List<int[]> boxes, IPixelFrame frame)
    {
        if (boxes.Count == 0)
            return (null, SimpleHp.AutoMap(frame).FromFallback
                ? "No HP orb found. Show the game's normal HUD with the orb visible, then try again."
                : "No HP orb found, but the simple-view HP text is there: switch Game view to Simple.");
        var box = Enumerable.Range(0, 4).Select(i => boxes.Select(b => b[i]).OrderBy(v => v).ElementAt(boxes.Count / 2)).ToArray();
        int nudge = 0;
        // Lower only the top edge: the box's top caught the rim; moving the whole box would push its bottom into the rim.
        while (HpDetector.HpFractionArc(frame, box[0], box[1], box[2], box[3]) < FullHpGate && nudge < MaxNudgePx) { box[1]++; box[3]--; nudge++; }
        if (HpDetector.HpFractionArc(frame, box[0], box[1], box[2], box[3]) < FullHpGate)
            return (null, "Found the orb, but HP doesn't read full. Fill your HP, then Auto-detect again.");
        var orbBox = new PixelRect(box[0], box[1], box[2], box[3]);
        var potion = new PixelPoint((int)(box[0] + HpDetector.PotionXPerWidth * box[2]),
                                    (int)(box[1] + HpDetector.PotionYPerHeight * box[3]) + OrbPotionBiasPx);
        return (s => s with { OrbBox = orbBox, OrbPotion = potion }, "Found the HP orb and the potion. Check the green dot sits on your HP potion.");
    }

    static (Func<AutoPotsSettings, AutoPotsSettings>?, string) DetectSimple(List<SimpleHp.MapResult> maps, IPixelFrame frame)
    {
        if (maps.Count == 0)
            return (null, HpDetector.AutoMapOrb(frame) != null
                ? "No \"HP: 100%\" text found, but the HP orb is there: switch Game view to Orb."
                : "No \"HP: 100%\" text found. Switch the game to simple view with HP full, then try again.");
        var map = maps.OrderBy(r => r.Left).ElementAt(maps.Count / 2);
        var box = new PixelRect(map.Left, map.Top, map.Width, map.Height);
        if (SimpleHp.BuildSignature(frame, box.X, box.Y, box.Width, box.Height, 1) is not { } signature)
            return (null, "Found the HP text but couldn't read it clearly. Try again with HP full.");
        var potion = new PixelPoint((int)map.PotionX, (int)map.PotionY);
        return (s => s with { SimpleBox = box, SimplePotion = potion, SimpleSignature = SimpleHp.Encode(signature) },
                map.PotionFound ? "Found the HP text and the potion." : "Found the HP text. Click your HP potion on the screen to place the dot.");
    }

    /// Simple view: a new "100%" template from the box (after it was moved by hand). HP must be full.
    public static string? RetakeTemplate(IPixelFrame frame, PixelRect box) =>
        SimpleHp.BuildSignature(frame, box.X, box.Y, box.Width, box.Height, 1) is { } signature ? SimpleHp.Encode(signature) : null;
}
