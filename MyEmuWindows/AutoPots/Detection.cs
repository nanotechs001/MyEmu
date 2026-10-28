// HP detection for AutoPots, ported line for line from the Mac app's AutoPotsDetection.swift (itself a port of
// autopotsCO's HpDetector.kt and SimpleHp.kt), so its measured constants and tests carry over unchanged.
// Pure functions over a frame of RGB pixels; no screen capture or input here.
namespace MyEmu.AutoPots;

/// A read-only frame of packed 0xRRGGBB pixels. The caller keeps (x, y) in bounds.
public interface IPixelFrame
{
    int Width { get; }
    int Height { get; }
    int Rgb(int x, int y);
}

/// The default view's HP orb: HP drains from the top, leaving a near-black band; remaining HP is
/// 1 − the drained share of rows.
public static class HpDetector
{
    /// A row counts as drained when more than this share of it is empty.
    public const float RowFill = 0.4f;
    /// Default max channel brightness for a pixel to count as drained.
    public const int DarkMax = 130;
    /// A drained pixel's red may not exceed green/blue by this much (neutral, not shaded red).
    public const int EmptyRedDominance = 22;

    // The sampled inner rectangle of the red-half box: off the curved left third, the divider,
    // the rim glow at the top and the bottom tip.
    public const float InsetLeft = 0.35f;
    public const float InsetRight = 0.08f;
    public const float InsetTop = 0.08f;
    public const float InsetBottom = 0.04f;

    static int Red(int c) => (c >> 16) & 0xFF;
    static int Green(int c) => (c >> 8) & 0xFF;
    static int Blue(int c) => c & 0xFF;

    public static bool IsEmpty(int rgb, int darkMax = DarkMax)
    {
        int r = Red(rgb), g = Green(rgb), b = Blue(rgb);
        return Math.Max(r, Math.Max(g, b)) < darkMax && (r - Math.Max(g, b)) < EmptyRedDominance;
    }

    /// Remaining-HP fraction 0…1 in the rectangle, or −1 if it's degenerate.
    public static float EmptyFraction(IPixelFrame frame, int left, int top, int width, int height, int darkMax = DarkMax)
    {
        int l = Math.Max(left, 0), t = Math.Max(top, 0);
        int r = Math.Min(left + width, frame.Width), b = Math.Min(top + height, frame.Height);
        if (r - l < 2 || b - t < 2) return -1;
        int emptyRows = 0;
        for (int y = t; y < b; y++)
        {
            int drained = 0;
            for (int x = l; x < r; x++) if (IsEmpty(frame.Rgb(x, y), darkMax)) drained++;
            if ((float)drained / (r - l) > RowFill) emptyRows++;
        }
        return 1 - (float)emptyRows / (b - t);
    }

    /// Remaining HP for the red-half box [left, top, width, height] (applies the inner inset).
    public static float HpFractionArc(IPixelFrame frame, int left, int top, int width, int height, int darkMax = DarkMax)
    {
        int sl = left + (int)(InsetLeft * width);
        int sr = left + width - (int)(InsetRight * width);
        int st = top + (int)(InsetTop * height);
        int sb = top + height - (int)(InsetBottom * height);
        return EmptyFraction(frame, sl, st, sr - sl, sb - st, darkMax);
    }

    /// Share of the sampled rectangle that is HP-red (~0.8 on the orb at full HP, ≤ ~0.2 off it),
    /// or −1 if degenerate. Sanity check for a hand-placed box.
    public static float HpRedFraction(IPixelFrame frame, int left, int top, int width, int height)
    {
        int sl = Math.Max(left + (int)(InsetLeft * width), 0);
        int sr = Math.Min(left + width - (int)(InsetRight * width), frame.Width);
        int st = Math.Max(top + (int)(InsetTop * height), 0);
        int sb = Math.Min(top + height - (int)(InsetBottom * height), frame.Height);
        if (sr - sl < 2 || sb - st < 2) return -1;
        int redCount = 0;
        for (int y = st; y < sb; y++)
            for (int x = sl; x < sr; x++)
            {
                var c = Classify(frame.Rgb(x, y));
                if (c == OrbClass.Red || c == OrbClass.DarkRed) redCount++;
            }
        return (float)redCount / ((sr - sl) * (sb - st));
    }

    // MARK: Automatic orb location

    const float OrbMinHeightPerWidth = 1.75f;
    const float OrbMaxHeightPerWidth = 2.15f;
    const float OrbTopMarginPerHeight = 0.13f;
    const float OrbHeightPerWidth = 2.25f;
    const float OrbMinBlue = 0.20f;
    const float OrbDividerMin = 0.42f;
    const float OrbDividerMax = 0.58f;
    const float SearchTop = 0.40f;
    const float SearchLeft = 0.30f;
    const float SearchRight = 0.70f;
    const float MinChordPerU = 0.012f;
    const float MaxGapPerH = 0.04f;
    const float GapRowsPerU = 0.03f;
    const int MaxCandidates = 6;
    const float MinRadiusPerU = 0.025f;
    const float MaxRadiusPerH = 0.12f;
    const float MinRowsPerRadius = 0.6f;
    const float MaxSpanPerRadius = 3.0f;
    const float MinRunPerRadius = 0.33f;
    const float MinWidthPerRadius = 0.7f;
    const float MaxWidthPerRadius = 1.45f;
    const float MinPeakPerRadius = 0.9f;

    /// The HP potion sits beside the orb: its tap point relative to the red-half box.
    public const float PotionXPerWidth = -0.80f;
    public const float PotionYPerHeight = 0.65f;

    enum OrbClass { Other, Red, DarkRed, Blue }

    static OrbClass Classify(int rgb)
    {
        int r = Red(rgb), g = Green(rgb), b = Blue(rgb);
        int gb = Math.Max(g, b);
        if (r >= 120 && r - gb >= 50) return OrbClass.Red;
        if (b >= 110 && b - Math.Max(r, g) >= 35) return OrbClass.Blue;
        if (r >= 80 && r - gb >= 40) return OrbClass.DarkRed;
        return OrbClass.Other;
    }

    /// The red half of the HP orb as [left, top, width, height], or null when no orb is visible
    /// (e.g. the game is in simple view). Finds the straight red|blue divider, then measures the half.
    public static int[]? AutoMapOrb(IPixelFrame frame)
    {
        int w = frame.Width, h = frame.Height;
        if (w < 32 || h < 32) return null;
        float u = Math.Min((float)h, (float)w * 9 / 16);
        int[]? best = null;
        int bestRows = -1;
        foreach (var c in OrbCandidates(frame, u))
        {
            int xr = c[0], yA = c[1], yB = c[2], rows = c[3], r = c[4];
            float divider = (float)xr / w;
            if (divider < OrbDividerMin || divider > OrbDividerMax) continue;
            if (r < MinRadiusPerU * u || r > MaxRadiusPerH * h) continue;
            if (rows < MinRowsPerRadius * r) continue;
            if (yB - yA > MaxSpanPerRadius * r) continue;
            var box = MeasureOrb(frame, xr, yA, yB, r);
            if (box == null) continue;
            if (rows > bestRows) { bestRows = rows; best = box; }
        }
        return best;
    }

    /// Stage 1: rows where a red run ends and a blue run starts across the divider bar, grouped by
    /// divider x into vertical chains: [dividerX, firstRow, lastRow, rowCount, radius], strongest first.
    static List<int[]> OrbCandidates(IPixelFrame frame, float u)
    {
        int w = frame.Width, h = frame.Height;
        int y0 = (int)(h * SearchTop);
        int x0 = (int)(w * SearchLeft), x1 = (int)(w * SearchRight);
        int bw = x1 - x0;
        int minChord = Math.Max(3, (int)(u * MinChordPerU));
        int maxGap = Math.Max(4, (int)(h * MaxGapPerH));

        var rowCls = new OrbClass[bw];
        var hits = new List<int[]>(); // [y, dividerX (last red), redLength, blueLength]
        for (int y = y0; y < h; y++)
        {
            for (int x = x0; x < x1; x++) rowCls[x - x0] = Classify(frame.Rgb(x, y));
            int run = 0;
            for (int i = 0; i <= bw; i++)
            {
                if (i < bw && rowCls[i] == OrbClass.Red) { run++; continue; }
                if (run >= minChord)
                {
                    // The blue half must start within the divider-bar gap (red resuming means it wasn't one).
                    int xb = -1;
                    int g = i;
                    int gEnd = Math.Min(bw - 1, i + maxGap);
                    while (g <= gEnd)
                    {
                        if (rowCls[g] == OrbClass.Blue) { xb = g; break; }
                        if (rowCls[g] == OrbClass.Red) break;
                        g++;
                    }
                    if (xb >= 0)
                    {
                        int k = xb;
                        while (k < bw && rowCls[k] == OrbClass.Blue) k++;
                        if (k - xb >= minChord) hits.Add(new[] { y, x0 + i - 1, run, k - xb });
                    }
                }
                run = 0;
            }
        }

        int gapRows = Math.Max(3, (int)(u * GapRowsPerU));
        var output = new List<int[]>();
        var pool = hits;
        var count = new int[w];
        while (pool.Count > 0 && output.Count < MaxCandidates)
        {
            // The divider x with the most rows (±2 px: the orb's is straight).
            Array.Clear(count);
            foreach (var hit in pool) count[hit[1]]++;
            int bestX = -1, bestN = 0;
            for (int x = x0; x < x1; x++)
            {
                if (count[x] == 0) continue;
                int n = 0;
                for (int d = -2; d <= 2; d++) { int k = x + d; if (k >= 0 && k < w) n += count[k]; }
                if (n > bestN) { bestN = n; bestX = x; }
            }
            if (bestN < 4) break;
            var group = pool.Where(p => Math.Abs(p[1] - bestX) <= 2).OrderBy(p => p[0]).ToList();
            pool = pool.Where(p => Math.Abs(p[1] - bestX) > 2).ToList();
            // Longest vertical chain of those rows.
            int bs = 0, bl = 0, s = 0;
            for (int i = 1; i <= group.Count; i++)
            {
                if (!(i == group.Count || group[i][0] - group[i - 1][0] > gapRows)) continue;
                if (i - s > bl) { bl = i - s; bs = s; }
                s = i;
            }
            var chain = group.GetRange(bs, bl);
            // The radius is the longest chord (highlights cut many short), capped against an outlier.
            var reds = chain.Select(c => c[2]).OrderBy(v => v).ToList();
            int p75 = reds[(int)(0.75f * (reds.Count - 1))];
            int radius = Math.Min(reds[^1], (int)(1.35f * p75) + 1);
            int xr = chain.Select(c => c[1]).OrderBy(v => v).ToList()[chain.Count / 2];
            output.Add(new[] { xr, chain[0][0], chain[^1][0], chain.Count, radius });
        }
        return output;
    }

    /// Stage 2: measure the red-half box around a stage-1 candidate.
    static int[]? MeasureOrb(IPixelFrame frame, int xr, int yA, int yB, int radius)
    {
        int w = frame.Width, h = frame.Height;
        int wx0 = Math.Max(0, xr - (int)(1.8f * radius)), wx1 = Math.Min(w, xr + 3);
        int wy0 = Math.Max(0, yA - radius), wy1 = Math.Min(h, yB + radius + 1);
        int n = wx1 - wx0;
        if (n <= 0 || wy1 <= wy0) return null;
        int minRun = Math.Max(3, (int)(MinRunPerRadius * radius));

        // Per column: strong-red count and the top/bottom of its longest strong-red run (shaded red
        // bridges a run; stray sparks don't join it).
        var colCount = new int[n];
        var colBottom = new int[n];
        var colTop = new int[n];
        for (int i = 0; i < n; i++)
        {
            int x = wx0 + i;
            int cnt = 0, best = 0, bottom = -1, top = -1;
            bool inRun = false; int runTop = 0, runBottom = 0;
            for (int y = wy0; y < wy1; y++)
            {
                var c = Classify(frame.Rgb(x, y));
                if (c == OrbClass.Red)
                {
                    cnt++;
                    if (!inRun) { inRun = true; runTop = y; }
                    runBottom = y;
                    if (runBottom - runTop + 1 > best) { best = runBottom - runTop + 1; bottom = runBottom; top = runTop; }
                }
                else if (!(inRun && c == OrbClass.DarkRed))
                {
                    inRun = false;
                }
            }
            colCount[i] = cnt; colBottom[i] = bottom; colTop[i] = top;
        }

        // Contiguous column runs (gap ≤ 3) with enough red.
        var runs = new List<int[]>();
        int previous = -10;
        for (int i = 0; i < n; i++)
        {
            if (colCount[i] < minRun) continue;
            if (runs.Count == 0 || i - previous > 3) runs.Add(new[] { i, i }); else runs[^1][1] = i;
            previous = i;
        }

        // The red half: the run ending at the divider, about the candidate's radius wide, with tall
        // red columns and the blue half beside it.
        (int Left, int Right)? pick = null;
        int pickBottom = 0;
        int pickDistance = int.MaxValue;
        int edgeTolerance = Math.Max(3, (int)(0.2f * radius));
        foreach (var run in runs)
        {
            int left = wx0 + run[0], right = wx0 + run[1];
            int rw = right - left + 1;
            int d = Math.Abs(right - xr);
            if (d > edgeTolerance) continue;
            if (rw < MinWidthPerRadius * radius || rw > MaxWidthPerRadius * radius) continue;
            int peak = 0;
            for (int i = run[0]; i <= run[1]; i++) peak = Math.Max(peak, colCount[i]);
            if (peak < MinPeakPerRadius * radius) continue;
            // Bottom edge: median of the last columns' run bottoms (divider side).
            var bottoms = new List<int>();
            for (int i = Math.Max(run[0], run[1] - 3); i <= run[1]; i++) if (colBottom[i] >= 0) bottoms.Add(colBottom[i]);
            if (bottoms.Count == 0) continue;
            bottoms.Sort();
            int bottom = bottoms[bottoms.Count / 2];
            if (BlueFraction(frame, right, rw, bottom) < OrbMinBlue) continue;
            if (d < pickDistance) { pickDistance = d; pick = (wx0 + run[0], wx0 + run[1]); pickBottom = bottom; }
        }
        if (pick is not { } chosen) return null;
        int bottomEdge = pickBottom;
        int runWidth = chosen.Right - chosen.Left + 1;

        // Top edge: the strong-red apex (3rd-smallest column top rides over spark-polluted columns),
        // trusted only when the height matches a full orb; otherwise the proportions decide.
        var tops = new List<int>();
        for (int x = chosen.Left; x <= chosen.Right; x++) if (colTop[x - wx0] >= 0) tops.Add(colTop[x - wx0]);
        if (tops.Count == 0) return null;
        tops.Sort();
        int apex = tops[Math.Min(2, tops.Count - 1)];
        int measuredH = bottomEdge - apex;
        int boxW = runWidth + 2;
        int boxLeft = chosen.Left;
        int boxTop, boxH;
        if (measuredH >= OrbMinHeightPerWidth * runWidth && measuredH <= OrbMaxHeightPerWidth * runWidth)
        {
            boxTop = apex - (int)(OrbTopMarginPerHeight * measuredH);
            boxH = bottomEdge + 3 - boxTop;
        }
        else
        {
            boxH = (int)(OrbHeightPerWidth * boxW);
            boxTop = bottomEdge + 3 - boxH;
        }
        // Grow the box 2.5% per side horizontally and 4.5% vertically: the dim rim and curved tips
        // sit just outside the strong red, and the drain band at the top registers earlier.
        int padX = Math.Max((int)(boxW * 0.025f), 1);
        int padY = Math.Max((int)(boxH * 0.045f), 2);
        boxLeft -= padX; boxW += 2 * padX;
        boxTop -= padY; boxH += 2 * padY;
        if (boxTop < 0) return null;
        return new[] { boxLeft, boxTop, boxW, boxH };
    }

    /// Share of MP-blue pixels right of the red run at the orb's height.
    static float BlueFraction(IPixelFrame frame, int right, int rw, int bottom)
    {
        int by0 = Math.Max((int)(bottom - 1.6f * rw), 0);
        int by1 = Math.Min((int)(bottom - 0.2f * rw), frame.Height);
        int bx0 = Math.Min(right + 4, frame.Width - 1);
        int bx1 = Math.Min(right + 4 + rw, frame.Width);
        if (by1 <= by0 || bx1 <= bx0) return 0;
        int blueCount = 0;
        for (int y = by0; y < by1; y++)
            for (int x = bx0; x < bx1; x++)
                if (Classify(frame.Rgb(x, y)) == OrbClass.Blue) blueCount++;
        return (float)blueCount / ((by1 - by0) * (bx1 - bx0));
    }
}

/// The game's simple view: "HP: 100%" text at the top left. A template of the "100%" glyphs taken
/// at full HP stops matching as soon as the value changes.
public static class SimpleHp
{
    public const int Bright = 200;

    static int Red(int c) => (c >> 16) & 0xFF;
    static int Green(int c) => (c >> 8) & 0xFF;
    static int Blue(int c) => c & 0xFF;

    public static bool IsTextBright(int rgb) => Math.Min(Red(rgb), Math.Min(Green(rgb), Blue(rgb))) >= Bright;

    public sealed record MapResult(int Left, int Top, int Width, int Height, float PotionX, float PotionY,
                                   bool FromFallback, bool PotionFound = false);

    // Reference positions (1280×860): digits box x92…140 y7…20, red potion at (139, 83). The game
    // anchors its UI to screen height, so everything scales by height.
    const float RefHeight = 860;
    const float BoxX = 92, BoxY = 7, BoxW = 49, BoxH = 14;
    const float PotX = 139, PotY = 83;

    static MapResult Fallback(int width, int height)
    {
        float s = height / RefHeight;
        return new MapResult((int)(BoxX * s), (int)(BoxY * s), Math.Max((int)(BoxW * s), 12),
                             Math.Max((int)(BoxH * s), 8), PotX * s, PotY * s, FromFallback: true);
    }

    /// Finds the "100%" digits and the red potion on a full-resolution frame; falls back to
    /// reference-scaled positions when the text can't be segmented.
    public static MapResult AutoMap(IPixelFrame frame)
    {
        int w = frame.Width, h = frame.Height;
        int winX = w / 4;
        int winY = Math.Min(Math.Max((int)(h * 0.045f), 24), h);

        // The text band is the longest run of strong bright rows.
        var rowCount = new int[winY];
        for (int y = 0; y < winY; y++)
        {
            int c = 0;
            for (int x = 0; x < winX; x++) if (IsTextBright(frame.Rgb(x, y))) c++;
            rowCount[y] = c;
        }
        int maxRow = rowCount.Length > 0 ? rowCount.Max() : 0;
        if (maxRow < 4) return Fallback(w, h);
        int cut = Math.Max(2, maxRow / 4);
        int bestS = -1, bestE = -1, s = -1;
        for (int y = 0; y < winY; y++)
        {
            if (rowCount[y] >= cut)
            {
                if (s < 0) s = y;
            }
            else if (s >= 0)
            {
                if (bestS < 0 || y - s > bestE - bestS) { bestS = s; bestE = y; }
                s = -1;
            }
        }
        if (s >= 0 && (bestS < 0 || winY - s > bestE - bestS)) { bestS = s; bestE = winY; }
        if (bestS < 0) return Fallback(w, h);
        int top = bestS;
        int textH = bestE - bestS;
        if (textH < 6) return Fallback(w, h);

        // Glyph clusters inside the band (a gap is ≥ 2 empty columns).
        var clusters = new List<int[]>();
        int lastBright = -3;
        for (int x = 0; x < winX; x++)
        {
            bool has = false;
            for (int y = top; y < bestE; y++) if (IsTextBright(frame.Rgb(x, y))) { has = true; break; }
            if (has)
            {
                if (clusters.Count == 0 || x - lastBright >= 2) clusters.Add(new[] { x, x }); else clusters[^1][1] = x;
                lastBright = x;
            }
        }
        if (clusters.Count < 4) return Fallback(w, h);

        // Only the first group ("HP: 100%"): cut at the big gap before "MP:".
        int groupGap = (int)(2.5f * textH);
        int lastIndex = clusters.Count - 1;
        for (int i = 1; i < clusters.Count; i++)
        {
            if (clusters[i][0] - clusters[i - 1][1] > groupGap) { lastIndex = i - 1; break; }
        }
        if (lastIndex < 3) return Fallback(w, h);

        // The widest gap in the group follows "HP:"; everything right of it is "100%".
        int gapIndex = -1, widest = 0;
        for (int i = 1; i <= lastIndex; i++)
        {
            int gap = clusters[i][0] - clusters[i - 1][1];
            if (gap > widest) { widest = gap; gapIndex = i; }
        }
        int right, left;
        int minSelection = (int)(1.5f * textH);
        if (gapIndex > 0 && widest >= Math.Max(4, textH / 3) && clusters[lastIndex][1] - clusters[gapIndex][0] >= minSelection)
        {
            left = clusters[gapIndex][0];
            right = clusters[lastIndex][1];
        }
        else
        {
            // No clear space: merge digits right to left, leaving out the last cluster ('%').
            int digitGap = Math.Max(3, textH / 2);
            right = clusters[lastIndex - 1][1];
            left = clusters[lastIndex - 1][0];
            if (lastIndex >= 2)
            {
                for (int i = lastIndex - 2; i >= 0; i--)
                {
                    if (left - clusters[i][1] <= digitGap) left = clusters[i][0]; else break;
                }
            }
        }
        if (right - left < 8) return Fallback(w, h);

        int boxL = Math.Max(left - 1, 0), boxT = Math.Max(top - 1, 0);
        int boxWidth = Math.Min(right - left + 3, w - boxL);
        int boxHeight = Math.Min(textH + 2, h - boxT);

        // The red potion: strong-red centroid below the text (dominance > 90 keeps the MP potion out).
        long sx = 0, sy = 0; int cnt = 0;
        int py0 = bestE + 4, py1 = Math.Min((int)(h * 0.18f), h), px1 = (int)(w * 0.2f);
        if (py1 > py0)
        {
            for (int y = py0; y < py1; y++)
                for (int x = 0; x < px1; x++)
                {
                    int c = frame.Rgb(x, y);
                    int r = Red(c);
                    if (r > 150 && r - Math.Max(Green(c), Blue(c)) > 90) { sx += x; sy += y; cnt++; }
                }
        }
        bool potionFound = cnt >= 60;
        float scale = h / RefHeight;
        return new MapResult(boxL, boxT, boxWidth, boxHeight,
                             potionFound ? (float)sx / cnt : PotX * scale,
                             potionFound ? (float)sy / cnt : PotY * scale,
                             FromFallback: false, PotionFound: potionFound);
    }

    // MARK: Adaptive template

    public const byte CellDark = 0, CellText = 1, CellEdge = 2;
    /// Below this the text is hidden or covered and the frame is unreadable.
    public const int MinTextLevel = 160;
    /// Required gap between the dark and bright means for there to be text at all.
    public const float MinContrast = 48;
    /// Neutral band around the split (anti-aliased glyph edges), never scored.
    public const float EdgeMargin = 24;
    const string SignaturePrefix = "2:";

    static int MinChannel(int c) => Math.Min(Red(c), Math.Min(Green(c), Blue(c)));

    /// Two-means glyph/background split of the box, or null when there's no text to split.
    static float? Threshold(int[] values)
    {
        if (values.Length == 0) return null;
        int lo = values.Min(), hi = values.Max();
        if (hi < MinTextLevel) return null;
        (float Low, float High)? Means(float t)
        {
            long sumL = 0, sumH = 0; int cntL = 0, cntH = 0;
            foreach (int v in values)
            {
                if (v < t) { sumL += v; cntL++; } else { sumH += v; cntH++; }
            }
            if (cntL == 0 || cntH == 0) return null;
            return ((float)sumL / cntL, (float)sumH / cntH);
        }
        float t = (float)(lo + hi) / 2;
        for (int i = 0; i < 8; i++)
        {
            if (Means(t) is not { } m) return null;
            float next = (m.Low + m.High) / 2;
            bool settled = Math.Abs(next - t) < 0.5f;
            t = next;
            if (settled) break;
        }
        if (Means(t) is not { } final || final.High - final.Low < MinContrast) return null;
        return t;
    }

    static int[]? BoxValues(IPixelFrame frame, int left, int top, int width, int height, int scale)
    {
        int sl = left / scale, st = top / scale, sw = width / scale, sh = height / scale;
        if (sw < 2 || sh < 2 || sl < 0 || st < 0 || sl + sw > frame.Width || st + sh > frame.Height) return null;
        var output = new int[sw * sh];
        int i = 0;
        for (int y = st; y < st + sh; y++) for (int x = sl; x < sl + sw; x++) output[i++] = MinChannel(frame.Rgb(x, y));
        return output;
    }

    /// The tri-state template of the box (screen coordinates, frame captured at 1/`scale`), taken
    /// while HP shows "100%". Null when the box has no readable text.
    public static byte[]? BuildSignature(IPixelFrame frame, int left, int top, int width, int height, int scale)
    {
        if (BoxValues(frame, left, top, width, height, scale) is not { } values || Threshold(values) is not { } t) return null;
        return values.Select(v =>
        {
            float d = v - t;
            return Math.Abs(d) <= EdgeMargin ? CellEdge : (d > 0 ? CellText : CellDark);
        }).ToArray();
    }

    /// How well the box still shows the calibrated "100%": 1 = exactly, 0 = no readable text,
    /// −1 = the template doesn't fit this capture (recalibrate).
    public static float Match(IPixelFrame frame, int left, int top, int width, int height, int scale,
                              byte[] signature, int signatureWidth, int signatureHeight)
    {
        int sw = width / scale, sh = height / scale;
        if (sw != signatureWidth || sh != signatureHeight || signature.Length != sw * sh) return -1;
        if (BoxValues(frame, left, top, width, height, scale) is not { } values) return -1;
        if (Threshold(values) is not { } t) return 0;
        int agree = 0, counted = 0;
        for (int i = 0; i < values.Length; i++)
        {
            if (signature[i] == CellEdge) continue;
            float d = values[i] - t;
            if (Math.Abs(d) <= EdgeMargin) continue; // a glyph edge in this frame
            counted++;
            if ((d > 0) == (signature[i] == CellText)) agree++;
        }
        if (counted < signature.Length / 4) return 0; // nothing recognizable left in the box
        return (float)agree / counted;
    }

    /// "2:" + one digit per cell; older strings decode to null (recalibrate once).
    public static string Encode(byte[] signature) => SignaturePrefix + string.Concat(signature.Select(c => (char)('0' + c)));

    public static byte[]? Decode(string s)
    {
        if (!s.StartsWith(SignaturePrefix) || s.Length <= SignaturePrefix.Length) return null;
        var output = new byte[s.Length - SignaturePrefix.Length];
        for (int i = 0; i < output.Length; i++)
        {
            int v = s[i + SignaturePrefix.Length] - '0';
            if (v < 0 || v > 2) return null;
            output[i] = (byte)v;
        }
        return output;
    }
}
